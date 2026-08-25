;;; node-identity-test.el --- Node identity boundary tests -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org)

(when load-file-name
  (add-to-list 'load-path
               (expand-file-name ".." (file-name-directory load-file-name))))

(require 'supertag-core-store)
(require 'supertag-service-node-identity)
(require 'supertag-service-org)
(require 'supertag-services-capture)
(require 'supertag-ui-commands)
(require 'supertag-ui-completion)
(require 'supertag-graph-ui)
(require 'supertag-board)
(require 'supertag-automation)

(defconst node-identity-test--root
  (expand-file-name ".." (file-name-directory load-file-name))
  "Repository root used by source-boundary assertions.")

(defmacro node-identity-test--with-clean-env (&rest body)
  "Run BODY with an isolated Store and Org ID cache."
  (declare (indent 0))
  `(let* ((tmp (make-temp-file "supertag-node-identity-test" t))
          (supertag-data-directory tmp)
          (supertag-db-file (expand-file-name "supertag-db.el" tmp))
          (supertag-db-backup-directory (expand-file-name "backups" tmp))
          (supertag--store nil)
          (org-id-locations nil)
          (org-id-files nil)
          (org-id-locations-file (expand-file-name "org-id-locations" tmp)))
     (unwind-protect
         (progn
           (supertag--ensure-store)
           ,@body)
       (dolist (buffer (buffer-list))
         (when-let* ((file (buffer-file-name buffer)))
           (when (string-prefix-p tmp file)
             (kill-buffer buffer))))
       (ignore-errors (delete-directory tmp t)))))

(ert-deftest node-identity-persists-heading-id-without-location-cache ()
  "Creating a heading identity writes Org but does not register a location."
  (node-identity-test--with-clean-env
    (let ((file (expand-file-name "node.org" tmp)))
      (with-temp-file file
        (insert "* Node\n\nBody\n"))
      (with-current-buffer (find-file-noselect file)
        (org-mode)
        (goto-char (point-max))
        (cl-letf (((symbol-function 'supertag-node-identity-new)
                   (lambda () "node-id")))
          (should (equal "node-id"
                         (supertag-node-identity-ensure-at-point))))
        (should (equal "node-id" (org-entry-get nil "ID")))
        (should-not org-id-locations)
        (save-buffer))
      (with-temp-buffer
        (insert-file-contents file)
        (should (re-search-forward "^:ID:[ \t]+node-id$" nil t))))))

(ert-deftest node-location-finds-store-node-with-empty-org-id-cache ()
  "Store file plus in-file ID resolves without touching Org's cache."
  (node-identity-test--with-clean-env
    (let ((file (expand-file-name "node.org" tmp)))
      (with-temp-file file
        (insert "* Node\n:PROPERTIES:\n:ID:       node-id\n:END:\n"))
      (supertag-store-put-entity
       :nodes "node-id"
       `(:id "node-id" :title "Node" :file ,file :position 99999 :level 1))
      (cl-letf (((symbol-function 'org-id-find)
                 (lambda (&rest _)
                   (ert-fail "Store-first lookup consulted org-id-find"))))
        (let ((marker (supertag-node-location-find "node-id")))
          (should (markerp marker))
          (should (equal file (buffer-file-name (marker-buffer marker))))
          (with-current-buffer (marker-buffer marker)
            (should (equal "Node"
                           (org-get-heading t t t t)))))))))

(ert-deftest node-location-places-file-node-at-file-start ()
  "File-node navigation uses the Store projection and stays at point-min."
  (node-identity-test--with-clean-env
    (let ((file (expand-file-name "file-node.org" tmp)))
      (with-temp-file file
        (insert ":PROPERTIES:\n:ID:       file-id\n:END:\n#+TITLE: File\n"))
      (supertag-store-put-entity
       :nodes "file-id"
       `(:id "file-id" :title "File" :file ,file :position 99999 :level 0))
      (let ((marker (supertag-node-location-find "file-id")))
        (should (markerp marker))
        (should (= (marker-position marker) 1))))))

(ert-deftest node-location-navigates-file-node-identities-with-empty-cache ()
  "Org-ID and Denote file nodes share Store-first navigation."
  (node-identity-test--with-clean-env
    (let ((org-file (expand-file-name "org-file-node.org" tmp))
          (denote-file (expand-file-name "denote-file-node.org" tmp)))
      (with-temp-file org-file
        (insert ":PROPERTIES:\n:ID: org-file-id\n:END:\n#+TITLE: Org\n"))
      (with-temp-file denote-file
        (insert "#+TITLE: Denote\n#+IDENTIFIER: denote-file-id\n"))
      (supertag-store-put-entity
       :nodes "org-file-id"
       `(:id "org-file-id" :title "Org" :file ,org-file
         :position 99999 :level 0 :link-type id))
      (supertag-store-put-entity
       :nodes "denote-file-id"
       `(:id "denote-file-id" :title "Denote" :file ,denote-file
         :position 99999 :level 0 :link-type denote))
      (cl-letf (((symbol-function 'org-id-find)
                 (lambda (&rest _)
                   (ert-fail "File-node navigation consulted org-id-find")))
                ((symbol-function 'pop-to-buffer)
                 (lambda (buffer &rest _)
                   (set-buffer buffer)
                   buffer))
                ((symbol-function 'switch-to-buffer)
                 (lambda (buffer &rest _)
                   (set-buffer buffer)
                   buffer))
                ((symbol-function 'org-show-context) #'ignore)
                ((symbol-function 'select-frame-set-input-focus) #'ignore))
        (dolist (pair `(("org-file-id" . ,org-file)
                        ("denote-file-id" . ,denote-file)))
          (let ((node-id (car pair))
                (file (cdr pair)))
            (save-current-buffer
              (supertag-goto-node node-id)
              (should (equal file (buffer-file-name)))
              (should (= (point) (point-min))))
            (save-current-buffer
              (supertag-graph-ui--jump-to-node node-id)
              (should (equal file (buffer-file-name)))
              (should (= (point) (point-min))))
            (save-current-buffer
              (supertag-board--on-open-node `((id . ,node-id)))
              (should (equal file (buffer-file-name)))
              (should (= (point) (point-min))))))))))

(ert-deftest node-location-rejects-child-id-as-file-node-identity ()
  "A child heading ID cannot validate a stale file-node projection."
  (node-identity-test--with-clean-env
    (let ((file (expand-file-name "wrong-file-node.org" tmp)))
      (with-temp-file file
        (insert "* Child\n:PROPERTIES:\n:ID: file-id\n:END:\n"))
      (supertag-store-put-entity
       :nodes "file-id"
       `(:id "file-id" :title "File" :file ,file
         :position 1 :level 0 :link-type id))
      (should-not (supertag-node-location-find "file-id"))
      (should-not (supertag-node-location-file "file-id")))))

(ert-deftest node-location-confines-org-id-compatibility-fallback ()
  "Unprojected nodes may still use the boundary's explicit fallback."
  (node-identity-test--with-clean-env
    (with-temp-buffer
      (org-mode)
      (insert "* Node\n")
      (goto-char (point-min))
      (let ((expected (point-marker)))
        (cl-letf (((symbol-function 'org-id-find)
                   (lambda (id markerp)
                     (should (equal "legacy-id" id))
                     (should (eq 'marker markerp))
                     expected)))
          (should (eq expected
                      (supertag-node-location-find "legacy-id"))))))))

(ert-deftest node-location-does-not-fallback-for-broken-store-projection ()
  "Known nodes with broken locations fail closed instead of using stale cache."
  (node-identity-test--with-clean-env
    (let ((missing-file (expand-file-name "missing.org" tmp))
          (fallback-used nil))
      (supertag-store-put-entity
       :nodes "node-id"
       `(:id "node-id" :title "Node" :file ,missing-file :level 1))
      (cl-letf (((symbol-function 'org-id-find)
                 (lambda (&rest _)
                   (setq fallback-used t)
                   (point-marker))))
        (should-not (supertag-node-location-find "node-id"))
        (should-not fallback-used)))))

(ert-deftest node-identity-ordinary-creation-works-with-empty-location-cache ()
  "The ordinary create command persists and projects identity without cache."
  (node-identity-test--with-clean-env
    (let ((file (expand-file-name "ordinary.org" tmp)))
      (with-temp-file file
        (insert "* Ordinary\n"))
      (with-current-buffer (find-file-noselect file)
        (org-mode)
        (goto-char (point-min))
        (cl-letf (((symbol-function 'supertag-node-identity-new)
                   (lambda () "ordinary-id"))
                  ((symbol-function 'org-id-find)
                   (lambda (&rest _)
                     (ert-fail "Ordinary creation consulted org-id-find"))))
          (should (equal "ordinary-id" (supertag-create-node)))
          (save-buffer)))
      (should (supertag-store-get-entity :nodes "ordinary-id"))
      (should (supertag-node-location-find "ordinary-id")))))

(ert-deftest node-identity-capture-works-with-empty-location-cache ()
  "Capture persists a standard ID and projects the node without cache."
  (node-identity-test--with-clean-env
    (let ((file (expand-file-name "capture.org" tmp)))
      (with-temp-file file)
      (cl-letf (((symbol-function 'org-id-find)
                 (lambda (&rest _)
                   (ert-fail "Capture consulted org-id-find"))))
        (let* ((buffer (find-file-noselect file))
               (result
                (supertag-capture--insert-node-into-buffer
                 buffer 1 1 "Captured" nil "Body" "capture-id"))
               (marker (plist-get result :marker)))
          (with-current-buffer buffer
            (goto-char marker)
            (should (equal "capture-id"
                           (supertag-capture-finalize-node-at-point))))
          (should (supertag-store-get-entity :nodes "capture-id"))
          (should (supertag-node-location-find "capture-id")))))))

(ert-deftest node-identity-completion-works-with-empty-location-cache ()
  "Completion persists, projects, and resolves an ID-less file-backed node."
  (node-identity-test--with-clean-env
    (let* ((file (expand-file-name "completion.org" tmp))
           (tag (supertag-tag-create '(:name "diary")))
           (tag-id (plist-get tag :id))
           node-id)
      (with-temp-file file
        (insert "* Node #diary"))
      (with-current-buffer (find-file-noselect file)
        (org-mode)
        (goto-char (point-max))
        (let ((candidate (propertize "diary" 'supertag-tag-id tag-id)))
          (cl-letf (((symbol-function 'org-id-find)
                     (lambda (&rest _)
                       (ert-fail "Completion consulted org-id-find"))))
            (supertag-completion--post-completion-action candidate)))
        (goto-char (point-min))
        (setq node-id (org-entry-get nil "ID"))
        (should (stringp node-id))
        (should (equal node-id
                       (plist-get (supertag-node-get node-id) :id)))
        (save-buffer))
      (should (equal (format "[[id:%s][Node]]" node-id)
                     (supertag-node-format-link node-id "Node")))
      (let ((marker (supertag-node-location-find node-id)))
        (should (markerp marker))
        (should (equal file (buffer-file-name (marker-buffer marker))))))))

(ert-deftest node-location-opens-org-id-link-with-empty-location-cache ()
  "Org id links follow the Store projection without Org's location cache."
  (node-identity-test--with-clean-env
    (let ((file (expand-file-name "node.org" tmp)))
      (with-temp-file file
        (insert "* Node\n:PROPERTIES:\n:ID:       node-id\n:END:\n"))
      (supertag-store-put-entity
       :nodes "node-id"
       `(:id "node-id" :title "Node" :file ,file :level 1))
      (cl-letf (((symbol-function 'org-id-find)
                 (lambda (&rest _)
                   (ert-fail "Org link lookup consulted org-id-find")))
                ((symbol-function 'supertag-sync--in-sync-scope-p)
                 (lambda (_) t))
                ((symbol-function 'pop-to-buffer)
                 (lambda (buffer &rest _)
                   (set-buffer buffer)
                   buffer))
                ((symbol-function 'org-show-context) #'ignore)
                ((symbol-function 'recenter) #'ignore))
        (should (supertag-service-org-follow-id "node-id"))
        (should (equal "Node" (org-get-heading t t t t)))))))

(ert-deftest node-location-ui-graph-and-board-use-store-with-empty-cache ()
  "Direct, graph, and board navigation share Store-first lookup."
  (node-identity-test--with-clean-env
    (let ((file (expand-file-name "navigation.org" tmp)))
      (with-temp-file file
        (insert "* Node\n:PROPERTIES:\n:ID:       node-id\n:END:\n"))
      (supertag-store-put-entity
       :nodes "node-id"
       `(:id "node-id" :title "Node" :file ,file :position 99999 :level 1))
      (cl-letf (((symbol-function 'org-id-find)
                 (lambda (&rest _)
                   (ert-fail "Navigation consulted org-id-find")))
                ((symbol-function 'pop-to-buffer)
                 (lambda (buffer &rest _)
                   (set-buffer buffer)
                   buffer))
                ((symbol-function 'switch-to-buffer)
                 (lambda (buffer &rest _)
                   (set-buffer buffer)
                   buffer))
                ((symbol-function 'org-show-context) #'ignore)
                ((symbol-function 'select-frame-set-input-focus) #'ignore))
        (save-current-buffer
          (supertag-goto-node "node-id")
          (should (equal "node-id" (org-entry-get nil "ID"))))
        (save-current-buffer
          (supertag-graph-ui--jump-to-node "node-id")
          (should (equal "node-id" (org-entry-get nil "ID"))))
        (save-current-buffer
          (supertag-board--on-open-node '((id . "node-id")))
          (should (equal "node-id" (org-entry-get nil "ID"))))))))

(ert-deftest node-location-automation-uses-store-file-with-empty-cache ()
  "Automation resolves the source file through the location boundary."
  (node-identity-test--with-clean-env
    (let ((source-file (expand-file-name "source.org" tmp))
          (target-file (expand-file-name "target.org" tmp))
          moved)
      (with-temp-file source-file
        (insert "* Node\n:PROPERTIES:\n:ID:       node-id\n:END:\n"))
      (with-temp-file target-file)
      (supertag-store-put-entity
       :nodes "node-id"
       `(:id "node-id" :title "Node" :file ,source-file :level 1))
      (cl-letf (((symbol-function 'org-id-find)
                 (lambda (&rest _)
                   (ert-fail "Automation consulted org-id-find")))
                ((symbol-function 'supertag-service-org-move-node-to-file)
                 (lambda (id file &rest _)
                   (setq moved (list id file))
                   t)))
        (supertag-automation-action-move-node
         "node-id" (list :target-file target-file))
        (should (equal (list "node-id" target-file) moved))))))

(ert-deftest node-location-automation-reports-broken-store-projection ()
  "Automation diagnoses both missing files and missing in-file IDs."
  (node-identity-test--with-clean-env
    (let ((target-file (expand-file-name "target.org" tmp))
          (missing-file (expand-file-name "missing.org" tmp))
          (wrong-file (expand-file-name "wrong.org" tmp))
          messages
          moved)
      (with-temp-file target-file)
      (with-temp-file wrong-file
        (insert "* Different node\n:PROPERTIES:\n:ID: other-id\n:END:\n"))
      (cl-letf (((symbol-function 'org-id-find)
                 (lambda (&rest _)
                   (ert-fail "Broken Store projection consulted org-id-find")))
                ((symbol-function 'supertag-service-org-move-node-to-file)
                 (lambda (&rest _)
                   (setq moved t)))
                ((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (push (apply #'format format-string args) messages))))
        (dolist (file (list missing-file wrong-file))
          (supertag-store-put-entity
           :nodes "node-id"
           `(:id "node-id" :title "Node" :file ,file :level 1))
          (supertag-automation-action-move-node
           "node-id" (list :target-file target-file))))
      (should-not moved)
      (should (= 2 (cl-count
                    "ERROR(:move-node): cannot resolve source for node node-id"
                    messages :test #'equal))))))

(ert-deftest node-location-board-reports-missing-node ()
  "Board navigation and mutation emit diagnostics for missing locations."
  (let (messages)
    (cl-letf (((symbol-function 'supertag-node-location-find) #'ignore)
              ((symbol-function 'message)
               (lambda (format-string &rest args)
                 (push (apply #'format format-string args) messages))))
      (supertag-board--on-open-node '((id . "missing-id")))
      (supertag-board--on-update-title
       '((nodeId . "missing-id") (title . "Title"))))
    (should (member "supertag-board: Cannot find node missing-id" messages))
    (should (member
             "supertag-board: Cannot update title for missing-id" messages))))

(ert-deftest node-identity-boundary-is-the-only-runtime-org-id-owner ()
  "Production feature modules do not bypass the identity/location boundary."
  (let* ((root node-identity-test--root)
         (boundary (expand-file-name "supertag-service-node-identity.el" root))
         (pattern
          "(\\s-*org-id-\\(?:new\\|get-create\\|find\\(?:-id-\\(?:file\\|in-file\\)\\)?\\|goto\\|add-location\\)\\_>")
         violations)
    (dolist (file (directory-files root t "\\`supertag-.*\\.el\\'"))
      (unless (equal file boundary)
        (with-temp-buffer
          (insert-file-contents file)
          (goto-char (point-min))
          (when (re-search-forward pattern nil t)
            (push (file-name-nondirectory file) violations)))))
    (should-not violations)))

(provide 'node-identity-test)
;;; node-identity-test.el ends here
