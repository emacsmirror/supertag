;;; supertag-summary-runner.el --- Run summary layout code in a child Emacs -*- lexical-binding: t; -*-

;;; Commentary:
;; Commands: none.
;; Dependencies: cl-lib, subr-x, seq.
;;
;; A summary panel's layout is code a model wrote.  That code never runs in
;; the user's session.  `supertag-summary' starts a child Emacs as
;;
;;   emacs -Q --batch -l supertag-summary-runner.el \
;;         -f supertag-summary-runner-main \
;;         CODE-FILE DATA-FILE OUT-FILE WIDTH [COMPONENTS-FILE]
;;
;; CODE-FILE holds one form, (lambda (data width) ...).  The form is refused
;; unless every function it names is on `supertag-summary-runner-allowed', so
;; it can compute and build lists and nothing else: no files, no processes,
;; no network, no buffers.  It then runs here and what it returns is printed
;; to OUT-FILE as plain data, which the session checks again before any of it
;; becomes a widget.
;;
;; COMPONENTS-FILE holds one form, a list of (NAME . (lambda ...)):
;; components written earlier.  Each is checked the same way and bound to
;; NAME around the layout code, which draws one with (funcall NAME ...).
;;
;; This file must stay loadable on its own, with no other Supertag code.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)

(defconst supertag-summary-runner-allowed
  '(;; structure
    lambda function quote \` let let* if when unless cond and or not progn prog1
    setq dolist dotimes push pop cl-incf cl-decf cl-loop when-let when-let*
    if-let if-let* apply funcall identity ignore
    ;; numbers
    + - * / % mod 1+ 1- min max abs float round floor ceiling truncate sqrt
    expt = /= < > <= >= zerop numberp integerp floatp cl-evenp cl-oddp
    number-sequence
    ;; lists
    car cdr cadr cddr caar cdar nth nthcdr cons list append length reverse
    nreverse last butlast member memq assoc assq alist-get plist-get plist-put
    mapcar mapc mapconcat sort null consp listp eq equal make-list delete-dups
    delq remove cl-remove-if cl-remove-if-not cl-reduce cl-sort cl-count-if
    cl-count cl-find cl-find-if cl-position cl-subseq cl-first cl-second
    cl-third cl-mapcar cl-some cl-every cl-remove-duplicates vector aref
    make-vector aset
    ;; strings and dates
    format concat substring string string-to-number number-to-string stringp
    string-prefix-p string-suffix-p string-match-p string-empty-p string-trim
    string-join split-string upcase downcase string< string> string=
    string-equal string-width truncate-string-to-width make-string
    format-time-string date-to-time float-time time-subtract time-add
    days-to-time decode-time encode-time current-time)
  "Every function, macro and special form layout code may name.")

(defun supertag-summary-runner--symbols (form)
  "Return every non-keyword symbol that occurs anywhere in FORM."
  (let (found)
    (cl-labels ((walk (part)
                  (cond ((consp part) (walk (car part)) (walk (cdr part)))
                        ((vectorp part) (mapc #'walk part))
                        ((and (symbolp part) part (not (keywordp part)))
                         (cl-pushnew part found)))))
      (walk form))
    found))

(defun supertag-summary-runner-refused (form &optional names)
  "Return the symbols in FORM that name something not allowed.
NAMES are component names, which FORM may use as variables even when Emacs
has a function of the same name."
  (cl-remove-if-not
   (lambda (symbol)
     (and (not (memq symbol supertag-summary-runner-allowed))
          (not (memq symbol names))
          (not (string-prefix-p "seq-" (symbol-name symbol)))
          (or (fboundp symbol) (special-form-p symbol))))
   (supertag-summary-runner--symbols form)))

(defun supertag-summary-runner--read (file)
  "Return the first form in FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (read (current-buffer))))

(defun supertag-summary-runner--components (file)
  "Return the checked (NAME . LAMBDA) components in FILE, or nil without FILE."
  (let* ((components (and file (file-exists-p file)
                          (supertag-summary-runner--read file)))
         (names (mapcar #'car-safe components)))
    (dolist (component components)
      (let ((name (car-safe component))
            (form (cdr-safe component)))
        (unless (and name (symbolp name) (eq (car-safe form) 'lambda))
          (error "组件 %s 必须是一个 (lambda (…) …) 表达式" name))
        (when-let* ((refused (supertag-summary-runner-refused form names)))
          (error "组件 %s 里出现了不允许的函数名：%s。如果你只是把它当变量名，请换一个名字"
                 name (mapconcat #'symbol-name refused "、")))))
    components))

(defun supertag-summary-runner-main ()
  "Check and run the layout code named on the command line.
Exit with status 1 and a line starting with ERROR: when it is refused or
fails."
  (pcase-let ((`(,code-file ,data-file ,out-file ,width . ,more)
               command-line-args-left))
    (setq command-line-args-left nil)
    (condition-case err
        (let* ((components (supertag-summary-runner--components (car more)))
               (form (supertag-summary-runner--read code-file))
               (refused (supertag-summary-runner-refused
                         form (mapcar #'car components))))
          (unless (eq (car-safe form) 'lambda)
            (error "代码必须是一个 (lambda (data width) ...) 表达式"))
          (when refused
            (error "代码里出现了不允许的函数名：%s。如果你只是把它当变量名，请换一个名字"
                   (mapconcat #'symbol-name refused "、")))
          (let ((frame (funcall
                        (eval `(let* ,(mapcar (lambda (component)
                                                (list (car component)
                                                      (cdr component)))
                                              components)
                                 ,form)
                              t)
                        (supertag-summary-runner--read data-file)
                        (string-to-number width)))
                (coding-system-for-write 'utf-8)
                (print-length nil)
                (print-level nil))
            (with-temp-file out-file
              (prin1 frame (current-buffer)))))
      (error
       (princ (format "ERROR: %s" (error-message-string err)))
       (kill-emacs 1)))))

(provide 'supertag-summary-runner)
;;; supertag-summary-runner.el ends here
