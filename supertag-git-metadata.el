;;; supertag-git-metadata.el --- Portable Git metadata -*- lexical-binding: t; -*-
;; Commands: none (used by supertag-git).
;; Dependencies: cl-lib, subr-x, supertag-core-persistence, supertag-tag,
;; supertag-automation.
;;; Commentary:
;; A data-only, versioned snapshot, never a serialized Store or executable file.
;; The last reconciled snapshot lives in the LOCAL Store's :meta collection so
;; it is saved with the entities it describes.  Entity-level three-way merging
;; preserves offline edits and deletions, including edits during async fetch.
;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'supertag-core-persistence)
(require 'supertag-tag)
(require 'supertag-automation)

(defconst supertag-git-metadata-file ".supertag-metadata.eld"
  "Root-relative, data-only portable metadata file.")
(defconst supertag-git-metadata--schema
  '((:tags :id :name :aliases :type :extends)
    (:automations :id :name :description :trigger :condition :actions :schedule :enabled))
  "Explicit portable properties; runtime state and timestamps stay local.")
(defvar supertag-git-metadata--importing nil
  "Non-nil while applying remote metadata without running automations.")

(defun supertag-git-metadata--key (root)
  "Return the local baseline key for ROOT."
  (concat "git-metadata:" (file-name-as-directory (file-truename root))))

(defun supertag-git-metadata--base (root)
  "Return the local baseline record for ROOT, or nil on first contact."
  (supertag-store-get-entity :meta (supertag-git-metadata--key root)))

(defun supertag-git-metadata--data-p (value &optional depth)
  "Whether VALUE is bounded plain data, never closures or reader objects."
  (and (< (or depth 0) 100)
       (cond ((or (null value) (stringp value) (numberp value) (symbolp value)) t)
             ((consp value)
              (and (proper-list-p value)
                   (cl-every (lambda (x) (supertag-git-metadata--data-p x (1+ (or depth 0)))) value)))
             (t nil))))

(defun supertag-git-metadata--project (collection entity)
  "Copy only portable properties of ENTITY in COLLECTION."
  (let (result)
    (dolist (key (cdr (assq collection supertag-git-metadata--schema)))
      (setq result (append result (list key (copy-tree (plist-get entity key))))))
    (unless (supertag-git-metadata--data-p result)
      (user-error "Metadata contains nonportable data (use named automation functions)"))
    (supertag--persistence--canonicalize-value result)))

(defun supertag-git-metadata--sort (records)
  "Sort RECORDS canonically by collection then ID."
  (sort records (lambda (a b)
                  (if (eq (car a) (car b)) (string< (cadr a) (cadr b))
                    (string< (symbol-name (car a)) (symbol-name (car b)))))))

(defun supertag-git-metadata-snapshot ()
  "Return deterministic portable records, without local projection state."
  (let (records)
    (dolist (schema supertag-git-metadata--schema)
      (maphash (lambda (id entity)
                 (push (list (car schema) id
                             (supertag-git-metadata--project (car schema) entity)) records))
               (supertag-store-get-collection (car schema))))
    (supertag-git-metadata--sort records)))

(defun supertag-git-metadata--validation-actions (actions)
  "Copy ACTIONS for validation, admitting the retired :update-field name.
This is only a validation adapter, not a migration or an executable rule."
  (mapcar
   (lambda (action)
     (let ((copy (copy-tree action)))
       (when (eq (plist-get copy :action) :update-field)
         (setq copy (plist-put copy :action :update-property)))
       (when (eq (plist-get copy :action) :case)
         (dolist (branch (plist-get (plist-get copy :params) :branches))
           (when (plist-member branch :actions)
             (setf (plist-get branch :actions)
                   (supertag-git-metadata--validation-actions
                    (plist-get branch :actions))))))
       copy))
   actions))

(defun supertag-git-metadata--validate-automation (entity)
  "Validate portable ENTITY, preserving known retired rule vocabulary.
Old rules are durable user data, even when V2 refuses to create them.
Only a disposable copy uses current names to check the surrounding shape;
the original trigger, actions and enabled flag travel unchanged."
  (let ((copy (copy-tree entity)))
    (when (eq (supertag-automation--normalize-trigger (plist-get copy :trigger))
              :on-field-change)
      (setq copy (plist-put copy :trigger :on-property-change)))
    (setq copy (plist-put copy :actions
                          (supertag-git-metadata--validation-actions
                           (plist-get copy :actions))))
    (condition-case err
        (supertag--validate-automation-data copy)
      (error (error "Metadata automation %s (%s): %s"
                    (plist-get entity :id) (plist-get entity :name)
                    (error-message-string err))))))

(defun supertag-git-metadata--validate (records)
  "Validate RECORDS completely before any Store mutation."
  (unless (and (proper-list-p records) (supertag-git-metadata--data-p records))
    (error "Invalid metadata records"))
  (let ((seen (make-hash-table :test 'equal))
        (tags (make-hash-table :test 'equal))
        (tokens (make-hash-table :test 'equal)))
    (dolist (record records)
      (unless (and (proper-list-p record) (= 3 (length record))
                   (assq (car record) supertag-git-metadata--schema)
                   (stringp (cadr record)) (not (string-empty-p (cadr record))))
        (error "Invalid metadata record: %S" record))
      (pcase-let ((`(,collection ,id ,entity) record))
        (unless (and (proper-list-p entity) (cl-evenp (length entity))
                     (equal id (plist-get entity :id)))
          (error "Invalid metadata entity: %s" id))
        (let ((keys nil) (tail entity))
          (while tail
            (let ((key (pop tail)))
              (pop tail)
              (unless (and (memq key (cdr (assq collection supertag-git-metadata--schema)))
                           (not (memq key keys)))
                (error "Unknown or duplicate metadata property: %S" key))
              (push key keys))))
        (when (gethash (list collection id) seen) (error "Duplicate metadata ID: %s" id))
        (puthash (list collection id) t seen)
        (unless (and (stringp (plist-get entity :name))
                     (not (string-empty-p (plist-get entity :name))))
          (error "Metadata name is empty: %s" id))
        (if (eq collection :tags)
            (progn
              (supertag--validate-tag-data entity)
              (puthash id entity tags)
              (dolist (token (supertag-tag--tokens id entity))
                (when-let* ((owner (gethash token tokens)))
                  (unless (equal owner id) (error "Metadata tag token collision: %s" token)))
                (puthash token id tokens)))
          (supertag-git-metadata--validate-automation entity))))
    ;; Validate the complete incoming graph, not against the old local graph.
    (let ((done (make-hash-table :test 'equal)))
      (cl-labels ((visit (id trail)
                   (when (member id trail) (error "Metadata tag inheritance cycle: %s" id))
                   (unless (gethash id tags) (error "Missing metadata parent: %s" id))
                   (unless (gethash id done)
                     (dolist (parent (plist-get (gethash id tags) :extends))
                       (visit parent (cons id trail)))
                     (puthash id t done))))
        (maphash (lambda (id _) (visit id nil)) tags))))
  records)

(defun supertag-git-metadata--path (root)
  "Return metadata path in ROOT, refusing symlinks and unsaved buffers."
  (let ((path (expand-file-name supertag-git-metadata-file root)))
    (when (file-symlink-p path) (user-error "Metadata must not be a symlink: %s" path))
    (when-let* ((buffer (get-file-buffer path)))
      (when (buffer-modified-p buffer) (user-error "Save metadata buffer first: %s" path)))
    path))

(defun supertag-git-metadata-read (root)
  "Read data from ROOT without loading or evaluating Lisp."
  (let ((path (supertag-git-metadata--path root)))
    (when (file-exists-p path)
      (when (> (file-attribute-size (file-attributes path)) (* 16 1024 1024))
        (error "Metadata file exceeds 16 MiB"))
      (with-temp-buffer
        (insert-file-contents path)
        (goto-char (point-min))
        (let* ((read-circle nil)
               (data (read (current-buffer))))
          (skip-chars-forward " \t\r\n")
          (unless (and (eobp) (proper-list-p data)
                       (eq (car data) :supertag-metadata) (equal (cadr data) 1))
            (error "Invalid or unsupported metadata format"))
          (supertag-git-metadata--validate (cddr data))
          (supertag-git-metadata--sort
           (mapcar (lambda (record)
                     (list (car record) (cadr record)
                           (supertag-git-metadata--project (car record) (nth 2 record))))
                   (cddr data))))))))

(defun supertag-git-metadata--merge (base local remote)
  "Three-way merge BASE, LOCAL and REMOTE, refusing competing entity edits."
  (let ((table (make-hash-table :test 'equal)) result)
    (cl-loop for records in (list base local remote) for column from 0 do
             (dolist (record records)
               (let* ((key (list (car record) (cadr record)))
                      (values (or (gethash key table) (vector nil nil nil))))
                 (aset values column record) (puthash key values table))))
    (maphash
     (lambda (key values)
       (let* ((b (aref values 0)) (l (aref values 1)) (r (aref values 2))
              (chosen (cond ((equal l r) l) ((equal l b) r) ((equal r b) l)
                            (t (user-error
                                "Metadata conflict %S: local edits retained; reconcile Store and %s before retrying"
                                key supertag-git-metadata-file)))))
         (when chosen (push chosen result)))) table)
    (supertag-git-metadata--validate result)
    (supertag-git-metadata--sort result)))

(defun supertag-git-metadata--write (root records)
  "Atomically write RECORDS in ROOT, one entity per line for Git merging."
  (let* ((path (supertag-git-metadata--path root))
         (temp (make-temp-file (expand-file-name ".supertag-metadata-tmp-" root))))
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'utf-8-unix)
                (print-length nil) (print-level nil) (print-quoted t)
                (print-escape-newlines t) (print-circle nil))
            (with-temp-file temp
              (insert "(:supertag-metadata 1\n")
              (dolist (record records) (prin1 record (current-buffer)) (insert "\n"))
              (insert ")\n")))
          (rename-file temp path t)
          (when-let* ((buffer (get-file-buffer path)))
            (with-current-buffer buffer (revert-buffer t t t))))
      (when (file-exists-p temp) (delete-file temp)))))

(defun supertag-git-metadata-pending-p (root)
  "Whether local portable facts differ from ROOT's persisted baseline."
  (not (equal (supertag-git-metadata-snapshot)
              (plist-get (supertag-git-metadata--base root) :snapshot))))

(defun supertag-git-metadata-reconcile (root &optional export)
  "Reconcile ROOT's data with the local Store; EXPORT also writes the result.
An absent file on first contact is not a deletion.  Once a baseline exists,
an absent file represents deletion of its portable records.  Conflicts fail
before writing anything.  Import never invokes rule actions or node writes."
  (let* ((base-record (supertag-git-metadata--base root))
         (base (plist-get base-record :snapshot))
         (local (supertag-git-metadata-snapshot))
         (remote (supertag-git-metadata-read root))
         (merged (supertag-git-metadata--merge base local remote))
         (baseline (if export merged remote))
         (supertag-git-metadata--importing t)
         (supertag-automation--enabled nil)
         (supertag-automation-sync--enabled nil))
    (when (or export base-record (file-exists-p (expand-file-name supertag-git-metadata-file root)))
      (supertag-with-transaction
        (dolist (schema supertag-git-metadata--schema)
          (let* ((collection (car schema))
                 (ids (mapcar #'cadr (cl-remove-if-not (lambda (r) (eq collection (car r))) merged))))
            (dolist (record local)
              (when (and (eq collection (car record)) (not (member (cadr record) ids)))
                (supertag-store-remove-entity collection (cadr record))))))
        (dolist (record merged)
          (pcase-let* ((`(,collection ,id ,entity) record)
                       (old (supertag-store-get-entity collection id)))
            (unless (equal entity (and old (supertag-git-metadata--project collection old)))
              (let ((updated (or (copy-tree old) (list :created-at (current-time)))))
                (setq updated (plist-put updated :modified-at (current-time)))
                (dolist (key (cdr (assq collection supertag-git-metadata--schema)))
                  (setq updated (plist-put updated key (copy-tree (plist-get entity key)))))
                (supertag-store-put-entity collection id updated)))))
        (when (and export (or (not (file-exists-p (expand-file-name supertag-git-metadata-file root)))
                                     (not (equal remote merged))))
          (supertag-git-metadata--write root merged))
        (unless (and base-record (equal base baseline))
          (supertag-store-put-entity :meta (supertag-git-metadata--key root)
                                     (list :snapshot baseline))
          (supertag-mark-dirty)))
      (unless (equal local merged)
        (supertag-mark-dirty)
        (supertag-tag-index-clear)
        ;; Refresh only changed rule schedules.  Re-registering every schedule
        ;; on a Tag import would erase local scheduler last-run bookkeeping.
        (let ((old-rules (cl-remove-if-not (lambda (r) (eq (car r) :automations)) local))
              (new-rules (cl-remove-if-not (lambda (r) (eq (car r) :automations)) merged)))
          (unless (equal old-rules new-rules)
            (dolist (record old-rules)
              (when (and (not (member record new-rules))
                         (eq (plist-get (nth 2 record) :trigger) :on-schedule))
                (supertag-automation--deregister-scheduled-rule (nth 2 record))))
            (supertag-rebuild-rule-index)
            (dolist (record new-rules)
              (when (and (not (member record old-rules))
                         (eq (plist-get (nth 2 record) :trigger) :on-schedule))
                (supertag-automation--register-scheduled-rule (nth 2 record))))))))
    merged))

(provide 'supertag-git-metadata)
;;; supertag-git-metadata.el ends here
