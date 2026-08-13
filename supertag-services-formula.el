;;; supertag-services-formula.el --- Formula evaluation service -*- lexical-binding: t; -*-

;;; Commentary:
;; This module owns the single formula grammar and evaluator for
;; Org-Supertag.  The canonical grammar is infix arithmetic over field
;; references, e.g. "(done / total) * 100".  Legacy formulas using the
;; "{{key}}"-placeholder prefix syntax (e.g. "(- 10 {{:progress}})") are
;; translated to the canonical grammar at evaluation time, so existing
;; configurations keep working without touching user data.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

;; NOTE: this module deliberately requires no other supertag modules at
;; load time.  `supertag-ops-relation' requires this module, and the ops
;; layer requires the query service which requires ops-relation -- a
;; load-time require of either direction would create a cycle.  The
;; field-value resolver therefore loads `supertag-ops-field' lazily at
;; evaluation time, when every module is already loaded.

;; --- Canonical infix parser and evaluator ---

(defun supertag-formula-tokenize (input)
  "Tokenize INPUT string into list of tokens."
  (let ((tokens nil)
        (i 0)
        (len (length input)))
    (while (< i len)
      (let ((ch (aref input i)))
        (cond
         ((member ch '(?\s ?\t ?\n ?\r))
          (setq i (1+ i)))
         ((= ch ?+)
          (push '+ tokens)
          (setq i (1+ i)))
         ((= ch ?-)
          (push '- tokens)
          (setq i (1+ i)))
         ((= ch ?*)
          (push '* tokens)
          (setq i (1+ i)))
         ((= ch ?/)
          (push '/ tokens)
          (setq i (1+ i)))
         ((= ch ?\()
          (push '*lparen* tokens)
          (setq i (1+ i)))
         ((= ch ?\))
          (push '*rparen* tokens)
          (setq i (1+ i)))
         ((and (>= ch ?0) (<= ch ?9))
          (let ((start i))
            (while (and (< i len)
                        (let ((c (aref input i)))
                          (or (and (>= c ?0) (<= c ?9))
                              (= c ?.))))
              (setq i (1+ i)))
            (push (string-to-number (substring input start i)) tokens)))
         ((or (and (>= ch ?a) (<= ch ?z))
              (and (>= ch ?A) (<= ch ?Z))
              (= ch ?_))
          (let ((start i))
            (while (and (< i len)
                        (let ((c (aref input i)))
                          (or (and (>= c ?a) (<= c ?z))
                              (and (>= c ?A) (<= c ?Z))
                              (and (>= c ?0) (<= c ?9))
                              (= c ?_))))
              (setq i (1+ i)))
            (push (substring input start i) tokens)))
         (t
          (error "Invalid character at position %d: %c" i ch)))))
    (nreverse tokens)))

(defun supertag-formula-parse (tokens)
  "Parse TOKENS into AST using recursive descent."
  (let ((pos 0)
        (len (length tokens)))
    (cl-labels
        ((peek ()
           (when (< pos len) (nth pos tokens)))
         (consume ()
           (prog1 (peek) (setq pos (1+ pos))))
         (expect (token)
           (if (eq (peek) token)
               (consume)
             (error "Expected %s but got %s at position %d" token (peek) pos)))
         (parse-expr ()
           (parse-additive))
         (parse-additive ()
           (let ((left (parse-multiplicative)))
             (while (member (peek) '(+ -))
               (let ((op (consume))
                     (right (parse-multiplicative)))
                 (setq left (list op left right))))
             left))
         (parse-multiplicative ()
           (let ((left (parse-primary)))
             (while (member (peek) '(* /))
               (let ((op (consume))
                     (right (parse-primary)))
                 (setq left (list op left right))))
             left))
         (parse-primary ()
           (let ((token (peek)))
             (cond
              ((null token)
               (error "Unexpected end of input"))
              ((eq token '*lparen*)
               (consume)
               (let ((expr (parse-expr)))
                 (expect '*rparen*)
                 expr))
              ((numberp token)
               (consume)
               (list '*number* token))
              ((stringp token)
               (consume)
               (list '*var* token))
              ((eq token '-)
               (consume)
               (list '*neg* (parse-primary)))
              (t
               (error "Unexpected token: %s" token))))))
      (let ((result (parse-expr)))
        (when (< pos len)
          (error "Unexpected token at end: %s" (peek)))
        result))))

(defun supertag-formula-eval (ast node-id &optional resolver)
  "Evaluate AST for NODE-ID, resolving variables via RESOLVER.
RESOLVER is a function taking a field name and returning its value.
Without RESOLVER, variables fall back to the global field store keyed by
field name with a 0 default (legacy behavior)."
  (pcase ast
    ((pred numberp) ast)
    (`(*number* ,n) n)
    (`(*var* ,field-name)
     (if resolver
         (funcall resolver field-name)
       (if (fboundp 'supertag-node-get-global-field)
           (supertag-node-get-global-field node-id field-name 0)
         0)))
    (`(+ ,a ,b) (+ (supertag-formula-eval a node-id resolver)
                   (supertag-formula-eval b node-id resolver)))
    (`(- ,a ,b) (- (supertag-formula-eval a node-id resolver)
                   (supertag-formula-eval b node-id resolver)))
    (`(* ,a ,b) (* (supertag-formula-eval a node-id resolver)
                   (supertag-formula-eval b node-id resolver)))
    (`(/ ,a ,b)
     (let ((denom (supertag-formula-eval b node-id resolver)))
       (if (zerop denom) 0
         (/ (float (supertag-formula-eval a node-id resolver)) denom))))
    (`(*neg* ,a) (- (supertag-formula-eval a node-id resolver)))
    (_ (error "Unknown AST node: %s" ast))))

(defun supertag-formula-parse-string (input)
  "Parse INPUT string to AST."
  (let ((tokens (supertag-formula-tokenize input)))
    (supertag-formula-parse tokens)))

(defun supertag-formula-eval-string (input node-id &optional resolver)
  "Parse and evaluate INPUT string for NODE-ID.
RESOLVER is the variable resolver passed to `supertag-formula-eval'."
  (let ((ast (supertag-formula-parse-string input)))
    (supertag-formula-eval ast node-id resolver)))

;; --- Legacy syntax translation ---

(defun supertag-formula--translate-placeholders (formula-string)
  "Replace {{KEY}} placeholders in FORMULA-STRING with bare KEY names."
  (replace-regexp-in-string
   "{{\\s-*:?\\([^{}]*?\\)\\s-*}}"
   (lambda (placeholder)
     (string-trim
      (if (string-match "{{\\s-*:?\\([^{}]*?\\)\\s-*}}" placeholder)
          (match-string 1 placeholder)
        "")))
   formula-string t t))

(defun supertag-formula--prefix-to-infix (form)
  "Translate legacy prefix FORM to canonical infix text.
Only binary + - * / over numbers and symbols are supported."
  (cond
   ((numberp form) (number-to-string form))
   ((symbolp form) (symbol-name form))
   ((and (consp form)
         (memq (car form) '(+ - * /))
         (= (length form) 3))
    (format "(%s %s %s)"
            (supertag-formula--prefix-to-infix (nth 1 form))
            (symbol-name (car form))
            (supertag-formula--prefix-to-infix (nth 2 form))))
   (t (error
       (concat "Unsupported legacy formula form %S; rewrite using the "
               "infix grammar, e.g. \"(done / total) * 100\"")
       form))))

(defun supertag-formula--canonicalize (formula-string)
  "Return FORMULA-STRING in the canonical infix grammar.
Legacy {{placeholder}} prefix formulas are translated; strings already
in the infix grammar pass through unchanged."
  (let* ((translated (supertag-formula--translate-placeholders formula-string))
         (parsed (condition-case nil
                     (read-from-string translated)
                   (error nil))))
    (if (and parsed
             (string-match-p "\\`[[:space:]]*\\'"
                             (substring translated (cdr parsed))))
        (supertag-formula--prefix-to-infix (car parsed))
      translated)))

;; --- Unified evaluation entry point ---

(defun supertag-rollup-apply (function-name values)
  "Reduce VALUES with FUNCTION-NAME.
FUNCTION-NAME is one of count, sum, avg/average, min, max, first, last,
unique-count, concat, or a function object applied to VALUES.
This is the single rollup reduction shared by Table, Virtual Column and
Automation so identical inputs produce identical results."
  (pcase function-name
    ((or 'count :count) (length values))
    ((or 'sum :sum) (apply #'+ (or values '(0))))
    ((or 'avg 'average :avg :average)
     (if values (/ (apply #'+ values) (length values)) 0))
    ((or 'min :min) (when values (apply #'min values)))
    ((or 'max :max) (when values (apply #'max values)))
    ((or 'first :first) (car values))
    ((or 'last :last) (car (last values)))
    ('unique-count (length (cl-remove-duplicates values :test #'equal)))
    ('concat (mapconcat #'identity values ", "))
    ((pred functionp) (funcall function-name values))
    (_ (message "Unknown rollup function: %S" function-name))))

(defun supertag-formula-evaluate (formula-string entity-data &optional field-getter)
  "Evaluate FORMULA-STRING for ENTITY-DATA.
Canonical grammar: infix arithmetic with field references as variables,
e.g. \"(done / total) * 100\".  Legacy {{key}}-placeholder prefix forms
are translated first.  Variables resolve through FIELD-GETTER when
supplied, otherwise through the global field model with schema defaults."
  (unless (and (stringp formula-string) (not (string-empty-p formula-string)))
    (error "FORMULA-STRING must be a non-empty string"))
  (let* ((canonical (supertag-formula--canonicalize formula-string))
         (node-id (plist-get entity-data :id))
         (resolver
          (or field-getter
              (and node-id
                   (lambda (name)
                     (require 'supertag-ops-field)
                     (supertag-field-get-with-default node-id nil name))))))
    (supertag-formula-eval
     (supertag-formula-parse-string canonical)
     node-id resolver)))

(provide 'supertag-services-formula)

;;; supertag-services-formula.el ends here
