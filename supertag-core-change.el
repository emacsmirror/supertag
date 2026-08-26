;;; supertag-core-change.el --- Canonical committed changes -*- lexical-binding: t; -*-

;;; Commentary:
;; This module owns the Canonical Change outer transaction, keeps first-touch
;; path details in a private CommitRecord, and publishes a bounded domain
;; summary after commit.  Migrated writers also receive one-way legacy event
;; parity from that private record while old consumers are retired.

;;; Code:

(require 'cl-lib)
(require 'supertag-core-store)
(require 'supertag-core-transform)

(defconst supertag-change--authorities
  '(:document :semantic :operational)
  "Authorities accepted by Canonical Change version 1.")

(defconst supertag-change--scopes
  '(:fact :projection :fact+projection)
  "Mutation scopes accepted by Canonical Change version 1.")

(defconst supertag-change--max-affected-entries 32
  "Maximum number of collection summaries in one Canonical Change.")

(defvar supertag-change--subscribers nil
  "Canonical Change callbacks, in subscription order.")

(defvar supertag-change--queue nil
  "FIFO of complete committed delivery batches awaiting delivery.")

(defvar supertag-change--dispatching nil
  "Non-nil while the Canonical Change FIFO is being drained.")

(defvar supertag-change--delivering-change-id nil
  "Change ID currently being delivered, used as nested commit causation.")

(defvar supertag-change--subscriber-errors nil
  "Captured subscriber failures, newest first.")

(defvar supertag-change--id-counter 0
  "Process-local suffix for Canonical Change IDs.")

(defvar supertag-change--suppress-legacy-store-changed nil
  "Non-nil while a managed body must suppress immediate legacy delivery.")

(defvar supertag-change--bridge-commit-count 0
  "Number of committed batches passed through the legacy bridge.")

(defvar supertag-change--bridge-total-path-count 0
  "Total number of path events passed through the legacy bridge.")

(defvar supertag-change--bridge-last-path-count 0
  "Number of path events in the most recently bridged commit.")

(defcustom supertag-change-bridge-debug nil
  "When non-nil, log bounded legacy bridge delivery diagnostics."
  :type 'boolean
  :group 'supertag)

(defun supertag-change--plist-p (value)
  "Return non-nil when VALUE is a proper keyword property list."
  (and (proper-list-p value)
       (zerop (% (length value) 2))
       (cl-loop for (key _value) on value by #'cddr
                always (keywordp key))))

(defun supertag-change--plist-keys (plist)
  "Return PLIST keys in order."
  (cl-loop for (key _value) on plist by #'cddr collect key))

(defun supertag-change--contains-raw-diff-p (value)
  "Return non-nil when VALUE contains Kernel-private raw diff vocabulary."
  (cond
   ((hash-table-p value) t)
   ((supertag-change--plist-p value)
    (cl-loop for (key item) on value by #'cddr
             thereis (or (memq key '(:path :paths :old :new :commit-record))
                         (supertag-change--contains-raw-diff-p item))))
   ((consp value)
    (cl-some #'supertag-change--contains-raw-diff-p value))
   (t nil)))

(defun supertag-change--validate-affected (affected)
  "Validate bounded AFFECTED collection/count summaries."
  (unless (and (proper-list-p affected)
               (<= (length affected)
                   supertag-change--max-affected-entries))
    (error "Canonical Change :affected must contain at most %d entries"
           supertag-change--max-affected-entries))
  (dolist (entry affected)
    (unless (and (supertag-change--plist-p entry)
                 (equal (sort (copy-sequence
                               (supertag-change--plist-keys entry))
                              (lambda (left right)
                                (string< (symbol-name left)
                                         (symbol-name right))))
                        '(:collection :count))
                 (keywordp (plist-get entry :collection))
                 (natnump (plist-get entry :count)))
      (error "Invalid Canonical Change :affected entry: %S" entry))))

(defun supertag-change--validate-envelope (envelope)
  "Validate and return Canonical Change ENVELOPE."
  (unless (supertag-change--plist-p envelope)
    (error "Canonical Change envelope must be a keyword plist"))
  (let ((allowed '(:authority :scope :operation :subject
                   :cardinality :affected :metadata)))
    (dolist (key (supertag-change--plist-keys envelope))
      (unless (memq key allowed)
        (error "Unknown Canonical Change envelope key: %S" key))))
  (dolist (required '(:authority :scope :operation :cardinality :affected))
    (unless (plist-member envelope required)
      (error "Canonical Change requires %S" required)))
  (unless (memq (plist-get envelope :authority)
                supertag-change--authorities)
    (error "Invalid Canonical Change authority: %S"
           (plist-get envelope :authority)))
  (unless (memq (plist-get envelope :scope) supertag-change--scopes)
    (error "Invalid Canonical Change scope: %S"
           (plist-get envelope :scope)))
  (unless (and (symbolp (plist-get envelope :operation))
               (plist-get envelope :operation))
    (error "Canonical Change :operation must be a non-nil symbol"))
  (unless (or (null (plist-get envelope :subject))
              (supertag-change--plist-p (plist-get envelope :subject)))
    (error "Canonical Change :subject must be nil or a keyword plist"))
  (unless (memq (plist-get envelope :cardinality) '(:single :batch))
    (error "Invalid Canonical Change cardinality: %S"
           (plist-get envelope :cardinality)))
  (unless (or (null (plist-get envelope :metadata))
              (supertag-change--plist-p (plist-get envelope :metadata)))
    (error "Canonical Change :metadata must be nil or a keyword plist"))
  (when (or (supertag-change--contains-raw-diff-p
             (plist-get envelope :subject))
            (supertag-change--contains-raw-diff-p
             (plist-get envelope :metadata)))
    (error "Canonical Change public data cannot contain raw Store diffs"))
  (supertag-change--validate-affected (plist-get envelope :affected))
  envelope)

(defun supertag-change--capture-commit-record ()
  "Return the changed first-touch entries in the active transaction.

Each private entry retains path/old/new data for commit plumbing.  Equal
first-touch writes are omitted so a logical no-op publishes no change."
  (let ((missing (make-symbol "supertag-change-missing")))
    (cl-loop
     for (path old-existed-p old-value) in (nreverse supertag--transaction-log)
     for current = (supertag-get path missing)
     for current-existed-p = (not (eq current missing))
     unless (and (eq (not (null old-existed-p)) current-existed-p)
                 (equal old-value (unless (eq current missing) current)))
     collect (list :path (copy-tree path)
                   :old-existed-p old-existed-p
                   :old (copy-tree old-value)
                   :new-existed-p current-existed-p
                   :new (unless (eq current missing) (copy-tree current))))))

(defun supertag-change--next-id ()
  "Return a process-unique Canonical Change ID."
  (format "change-%d-%d-%d"
          (emacs-pid)
          (truncate (* 1000000 (float-time)))
          (cl-incf supertag-change--id-counter)))

(defun supertag-change--make-change (envelope)
  "Build a public Canonical Change from validated ENVELOPE."
  (list :version 1
        :change-id (supertag-change--next-id)
        :causation-id supertag-change--delivering-change-id
        :authority (plist-get envelope :authority)
        :scope (plist-get envelope :scope)
        :operation (plist-get envelope :operation)
        :subject (copy-tree (plist-get envelope :subject))
        :cardinality (plist-get envelope :cardinality)
        :affected (copy-tree (plist-get envelope :affected))
        :metadata (copy-tree (plist-get envelope :metadata))))

(defun supertag-change--legacy-subscriber-count ()
  "Return the current number of legacy `:store-changed' subscribers."
  (if (hash-table-p supertag--subscribers)
      (length (gethash :store-changed supertag--subscribers))
    0))

(defun supertag-change--assert-legacy-topic-available (callback)
  "Reject legacy subscription when CALLBACK already receives Canonical Change."
  (when (memq callback supertag-change--subscribers)
    (error "Callback cannot subscribe to both Canonical Change and :store-changed")))

(defun supertag-change-bridge-diagnostics ()
  "Return bounded counters for the temporary one-way legacy bridge."
  (list :legacy-subscriber-count
        (supertag-change--legacy-subscriber-count)
        :bridged-commit-count supertag-change--bridge-commit-count
        :total-path-count supertag-change--bridge-total-path-count
        :last-commit-path-count supertag-change--bridge-last-path-count))

(defun supertag-change-subscribe (callback)
  "Subscribe CALLBACK to committed Canonical Changes.
Return an idempotent function that unsubscribes CALLBACK."
  (unless (functionp callback)
    (error "Canonical Change subscriber must be callable"))
  (when (and (hash-table-p supertag--subscribers)
             (memq callback
                   (gethash :store-changed supertag--subscribers)))
    (error "Callback cannot subscribe to both Canonical Change and :store-changed"))
  (setq supertag-change--subscribers
        (append supertag-change--subscribers (list callback)))
  (let ((subscribed t))
    (lambda ()
      (when subscribed
        (setq subscribed nil)
        (setq supertag-change--subscribers
              (delq callback supertag-change--subscribers))))))

(defun supertag-change--deliver-canonical (change)
  "Deliver committed CHANGE to a stable snapshot of subscribers."
  (dolist (subscriber (copy-sequence supertag-change--subscribers))
    (condition-case cause
        (funcall subscriber change)
      (error
       (push (list :change-id (plist-get change :change-id)
                   :subscriber subscriber
                   :cause cause)
             supertag-change--subscriber-errors)
       (message "[supertag] Canonical Change subscriber failed: %s"
                (error-message-string cause))))))

(defun supertag-change--deliver-batch (batch)
  "Deliver private BATCH with Canonical Change before its legacy path events."
  (let* ((change (plist-get batch :change))
         (commit-record (plist-get batch :commit-record))
         (supertag-change--delivering-change-id
          (plist-get change :change-id)))
    (supertag-change--deliver-canonical change)
    (dolist (entry commit-record)
      (supertag-emit-event :store-changed
                           (plist-get entry :path)
                           (plist-get entry :old)
                           (plist-get entry :new)))))

(defun supertag-change--drain ()
  "Synchronously drain the Canonical Change FIFO without reentry."
  (unless supertag-change--dispatching
    (let ((supertag-change--dispatching t))
      (while supertag-change--queue
        (let ((batch (pop supertag-change--queue)))
          (supertag-change--deliver-batch batch))))))

(defun supertag-change--enqueue (change commit-record)
  "Append one committed CHANGE/COMMIT-RECORD batch to the delivery FIFO."
  (let ((path-count (length commit-record)))
    (cl-incf supertag-change--bridge-commit-count)
    (cl-incf supertag-change--bridge-total-path-count path-count)
    (setq supertag-change--bridge-last-path-count path-count)
    (when supertag-change-bridge-debug
      (message
       "[supertag] Legacy bridge commit %s: %d path event(s), %d subscriber(s)"
       (plist-get change :change-id)
       path-count
       (supertag-change--legacy-subscriber-count))))
  (setq supertag-change--queue
        (nconc supertag-change--queue
               (list (list :change change
                           :commit-record commit-record))))
  (supertag-change--drain))

(defun supertag-change-commit (envelope body)
  "Run BODY atomically and publish one Canonical Change for a real mutation.

ENVELOPE contains bounded domain metadata; raw Store diffs stay in a private,
short-lived CommitRecord.  This initial seam must own the outer transaction,
so invoking it from an already-active transaction is rejected.  A subscriber
may invoke it safely: the nested committed change joins the FIFO and is not
delivered until the current change finishes.  Return BODY's result."
  (supertag-change--validate-envelope envelope)
  (unless (functionp body)
    (error "Canonical Change body must be callable"))
  (when supertag--transaction-active
    (error "Canonical Change seam must own the outer transaction"))
  (let (commit-record result)
    (let ((supertag-change--suppress-legacy-store-changed t))
      (setq result
            (supertag-with-transaction
              (prog1 (funcall body)
                (setq commit-record
                      (supertag-change--capture-commit-record))))))
    (when commit-record
      (supertag-change--enqueue
       (supertag-change--make-change envelope)
       commit-record))
    result))

(provide 'supertag-core-change)
;;; supertag-core-change.el ends here
