;;; compiler-regression-test.el --- Compilation-sensitive paths -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'bytecomp)
(require 'supertag-node)
(require 'supertag-automation)
(load (expand-file-name "move-nodes-position-test.el"
                        (file-name-directory (or load-file-name buffer-file-name))))

(defvar ivy-mode)

(ert-deftest supertag-compiler-ivy-preview-callback-is-explicit ()
  (let ((ivy-mode t) previewed)
    (cl-letf (((symbol-function 'supertag-ui--build-node-candidates)
               (lambda () '(("Node" . "node-id"))))
              ((symbol-function 'ivy-current-match) (lambda () "Node"))
              ((symbol-function 'ivy-read)
               (lambda (_prompt _candidates &rest options)
                 ;; Ivy invokes :update-fn without arguments.
                 (funcall (plist-get options :update-fn))
                 "Node"))
              ((symbol-function 'supertag-goto-node)
               (lambda (id &optional _preview) (push id previewed))))
      (should (equal "node-id" (supertag-ui-select-node nil nil t)))
      (should (equal '("node-id") previewed)))))

(ert-deftest supertag-compiler-event-queue-remains-fifo ()
  (let ((supertag-automation--event-queue nil)
        (supertag-automation--processing-timer 'pending)
        seen)
    (let ((handler (lambda (value) (push value seen))))
      (push (list handler 'first) supertag-automation--event-queue)
      (push (list handler 'second) supertag-automation--event-queue))
    (supertag-automation--process-event-queue)
    (should (equal '(second first) seen))
    (should-not supertag-automation--event-queue)
    (should-not supertag-automation--processing-timer)
    (supertag-automation--process-event-queue)
    (should (equal '(second first) seen))))

(ert-deftest supertag-compiler-idless-move-compensates-identity-error ()
  (let ((byte-compile-error-on-warn t)
        (move (symbol-function 'supertag-service-org-move-nodes)))
    (cl-letf (((symbol-function 'supertag-service-org-move-nodes)
               (byte-compile move)))
      (supertag-position-test--fixture
        (with-current-buffer bb
          (erase-buffer) (insert "* Unidentified\nBody\n") (goto-char 1))
        (let ((marker (with-current-buffer bb (point-marker))))
          (cl-letf (((symbol-function 'supertag-node-identity-ensure-at-point)
                     (lambda ()
                       (org-entry-put nil "ID" "temporary-id")
                       (error "Identity creation failed after editing"))))
            (should-error (supertag-service-org-move-nodes (list marker) c)))
          ;; The snapshot must have been marked edited before identity creation.
          (with-current-buffer bb
            (should (equal "* Unidentified\nBody\n" (buffer-string))))
          (should (equal btext (supertag-position-test--disk b)))
          (should (equal ctext (supertag-position-test--disk c))))))))

(provide 'compiler-regression-test)
