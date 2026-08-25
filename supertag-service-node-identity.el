;;; supertag-service-node-identity.el --- Node identity and location boundary -*- lexical-binding: t; -*-

;;; Commentary:
;; Org owns persisted node identity as the heading's ID property.  The
;; Supertag Store owns the projected file location.  This module is the only
;; runtime boundary that joins those two facts.  Org's global ID location
;; cache is an optional compatibility fallback, never the primary authority.

;;; Code:

(require 'org)
(require 'org-id)
(require 'subr-x)
(require 'supertag-core-store)

(defgroup supertag-node-identity nil
  "Node identity and Store-first location lookup."
  :group 'supertag)

(defcustom supertag-node-location-org-id-fallback t
  "When non-nil, use `org-id-find' for nodes absent from the Store.

This fallback exists for nodes that have not yet been projected into the
Supertag Store.  Runtime callers should use this service instead of consulting
`org-id-locations' directly."
  :type 'boolean
  :group 'supertag-node-identity)

(defun supertag-node-identity-new ()
  "Return a new ID suitable for an Org node.

ID generation uses Org's configured ID method but does not register a global
file location."
  (org-id-new))

(defun supertag-node-identity-ensure-at-point (&optional explicit-id)
  "Return the containing heading's persisted ID, creating it when absent.

The ID property is a Document Fact and is therefore written to the Org buffer.
The caller decides when to save and project that buffer.  No
`org-id-locations' entry is created here.  When EXPLICIT-ID is non-nil, persist
that value and reject a conflicting existing ID."
  (save-excursion
    (unless (or (org-at-heading-p) (org-back-to-heading t))
      (user-error "Point must be inside an Org heading."))
    (let ((current-id (org-entry-get nil "ID" nil)))
      (when (and explicit-id current-id (not (equal explicit-id current-id)))
        (user-error "Heading already has a different ID: %s" current-id))
      (or current-id
          (let ((node-id (or explicit-id (supertag-node-identity-new))))
            (org-entry-put nil "ID" node-id)
            node-id)))))

(defun supertag-node-location--id-property-position (node-id)
  "Return NODE-ID's property position in the widened current buffer."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (when (re-search-forward
             (concat "^[ \t]*:ID:[ \t]*"
                     (regexp-quote node-id)
                     "[ \t]*$")
             nil t)
        (point)))))

(defun supertag-node-location--heading-position (node-id)
  "Return NODE-ID's heading position in the widened current buffer."
  (when-let* ((property-position
               (supertag-node-location--id-property-position node-id)))
    (save-excursion
      (goto-char property-position)
      (org-back-to-heading t)
      (point))))

(defun supertag-node-location--file-drawer-end ()
  "Return the end of the file-level property drawer, or nil."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (skip-chars-forward " \t\r\n")
      (when (looking-at "^:PROPERTIES:[ \t]*$")
        (re-search-forward "^:END:[ \t]*$" nil t)))))

(defun supertag-node-location--file-org-id ()
  "Return the ID in the current buffer's file-level drawer, or nil."
  (when-let* ((drawer-end (supertag-node-location--file-drawer-end)))
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (when (re-search-forward "^:ID:[ \t]*\\(.+?\\)[ \t]*$"
                                 drawer-end t)
          (string-trim (match-string-no-properties 1)))))))

(defun supertag-node-location--file-denote-id ()
  "Return the current buffer's Denote identifier, or nil."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (when (re-search-forward "^#\\+IDENTIFIER:[ \t]*\\(.+?\\)[ \t]*$"
                               (min 2000 (point-max)) t)
        (string-trim (match-string-no-properties 1))))))

(defun supertag-node-location--file-identity-matches-p (node-id link-type)
  "Return non-nil when NODE-ID matches the file identity for LINK-TYPE."
  (pcase link-type
    ('id (equal node-id (supertag-node-location--file-org-id)))
    ('denote (equal node-id (supertag-node-location--file-denote-id)))
    (_ (or (equal node-id (supertag-node-location--file-org-id))
           (equal node-id (supertag-node-location--file-denote-id))))))

(defun supertag-node-location--position (node-id level link-type)
  "Return NODE-ID's current-buffer position for LEVEL and LINK-TYPE."
  (if (zerop (or level 1))
      (when (supertag-node-location--file-identity-matches-p
             node-id link-type)
        (save-restriction
          (widen)
          (point-min)))
    (supertag-node-location--heading-position node-id)))

(defun supertag-node-location-goto-current-buffer (node-id)
  "Move point to NODE-ID's heading in the current Org buffer.

Searches the widened buffer directly and does not consult
`org-id-locations'.  Return non-nil on success, leaving point unchanged on
failure."
  (when (and (stringp node-id) (not (string-empty-p node-id)))
    (let* ((node (supertag-store-get-entity :nodes node-id))
           (level (and (listp node) (plist-get node :level)))
           (link-type (and (listp node) (plist-get node :link-type)))
           (position (supertag-node-location--position
                      node-id level link-type)))
      (when (and position
                 (<= (point-min) position)
                 (<= position (point-max)))
        (goto-char position)
        t))))

(defun supertag-node-location--store-marker (node-id)
  "Return NODE-ID's marker using its projected Store location."
  (let* ((node (supertag-store-get-entity :nodes node-id))
         (file (and (listp node) (plist-get node :file)))
         (level (and (listp node) (plist-get node :level)))
         (link-type (and (listp node) (plist-get node :link-type)))
         (buffer (and (stringp file)
                      (file-exists-p file)
                      (find-file-noselect file)))
         (position (and buffer
                        (with-current-buffer buffer
                          (supertag-node-location--position
                           node-id level link-type)))))
    (when position
      (with-current-buffer buffer
        (copy-marker position)))))

(defun supertag-node-location-find (node-id)
  "Return a marker for NODE-ID using Store-first location lookup.

When the Store cannot resolve NODE-ID and
`supertag-node-location-org-id-fallback' is non-nil, use `org-id-find' as a
confined compatibility fallback.  A projected node that has a missing file or
missing in-file ID fails closed; it never falls back to a stale cache entry."
  (let ((node (supertag-store-get-entity :nodes node-id)))
    (if node
        (supertag-node-location--store-marker node-id)
      (when supertag-node-location-org-id-fallback
        (org-id-find node-id 'marker)))))

(defun supertag-node-location-file (node-id)
  "Return NODE-ID's verified source file using Store-first location lookup."
  (let ((node (supertag-store-get-entity :nodes node-id)))
    (if node
        (when-let* ((marker (supertag-node-location--store-marker node-id))
                    (buffer (marker-buffer marker)))
          (buffer-file-name buffer))
      (when-let* ((marker (and supertag-node-location-org-id-fallback
                              (org-id-find node-id 'marker)))
                  (buffer (marker-buffer marker)))
        (buffer-file-name buffer)))))

(provide 'supertag-service-node-identity)
;;; supertag-service-node-identity.el ends here
