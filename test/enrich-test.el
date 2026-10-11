;;; enrich-test.el --- Per-line, source-backed enrichment review -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'document-fixture)
(require 'supertag-enrich)
(require 'supertag-embark)

(defconst supertag-enrich-test--passages
  '((1 (:file "book.org" :title "Book" :beg 10 :end 80 :text "short preview")
       "A full passage.\n  Whitespace\t changes are fine. Exact evidence.")
    (2 (:file "other.org" :title "Other book" :beg 20 :end 90)
       "A different source.")))

(defmacro supertag-enrich-test-with-request (&rest body)
  "Run BODY with mocked optional APIs and captured REQUESTS and QUERIES."
  (declare (indent 0))
  `(let (requests queries previews followed)
     (cl-letf (((symbol-plist 'chai-context-citation) nil))
       (define-button-type 'chai-context-citation
         'action (lambda (button) (setq followed (button-get button 'chai-hit)))
         'follow-link t)
       (unwind-protect
           (cl-letf (((symbol-function 'chai-context-for)
                      (lambda (query &optional _filters)
                        (push query queries)
                        (unless (equal query "Unsupported")
                          (copy-tree supertag-enrich-test--passages))))
                     ((symbol-function 'chai-index-book-at) #'ignore)
                     ((symbol-function 'chai-context-source-name)
                      (lambda (hit) (plist-get hit :title)))
                     ((symbol-function 'chai-context-hit)
                      (lambda (passages number) (nth 1 (nth (1- number) passages))))
                     ((symbol-function 'superchat-runtime-submit) #'ignore)
                     ((symbol-function 'superchat-sink-create) #'list)
                     ((symbol-function 'supertag-ai--submit)
                      (lambda (request) (push request requests) '(:run-id "run")))
                     ((symbol-function 'display-buffer)
                      (lambda (buffer &rest _) (push buffer previews) nil)))
             ,@body)
         (dolist (buffer previews)
           (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(defun supertag-enrich-test--deliver (request text &optional status)
  "Deliver TEXT and STATUS through REQUEST's captured Sink."
  (funcall (plist-get (plist-get request :sink) (if status :error :final))
           '(:run-id "run") (list :text text :status (or status 'completed))))

(defun supertag-enrich-test--lines ()
  "Return two separately numbered supported lines and one unsupported line."
  (list (list :id 1 :original "First" :passages supertag-enrich-test--passages)
        (list :id 2 :original "Second"
              :passages '((1 (:title "Third book") "Only the second line's evidence.")))
        (list :id 3 :original "Unsupported" :passages nil)))

(ert-deftest supertag-enrich-lines-strip-prefixes-and-skip-org-constructs ()
  (should
   (equal
    (supertag-enrich--lines
     (concat "First line\nSecond line\n\n"
             "- [ ] Task\n+ [X] Done\n  * [-] Nested\n"
             "1. Numbered\n2) [x] Numbered check\n- Term :: Definition\n\n"
             ":NOTES:\nDrawer secret\n:END:\n\n"
             "#+begin_src text\nSource secret\n#+end_src\n\n"
             "#+begin_quote\nQuoted secret\n#+end_quote\n\n"
             "#+begin_custom\nSpecial secret\n#+end_custom\n\n"
             "#+BEGIN: clocktable\nDynamic secret\n#+END:\n\n"
             "| Table | secret |\n|-------+--------|\n\n"
             "#+KEYWORD: secret\n# Comment secret\n#\n\n"
             ": Fixed width secret\n\n"
             "#+caption: Affiliated secret\nFinal line\n")
     "Fallback")
    '("First line" "Second line" "Task" "Done" "Nested" "Numbered"
      "Numbered check" "Term :: Definition" "Final line"))))

(ert-deftest supertag-enrich-lines-title-fallback-and-plain-hashtags ()
  (dolist (body '("" "\n \t\n" ":DRAWER:\nHidden\n:END:\n"
                 "#+begin_example\nHidden\n#+end_example\n"
                 "| hidden |\n# comment\n#+KEY: value\n"))
    (should (equal (supertag-enrich--lines body "Title") '("Title"))))
  (should (equal (supertag-enrich--lines "#topic is text\n[ ] Checklist\n" "Title")
                 '("#topic is text" "Checklist"))))

(ert-deftest supertag-enrich-heading-body-range-and-one-request-with-own-passages ()
  (supertag-enrich-test-with-request
    (with-temp-buffer
      (org-mode)
      (insert "* Parent\n:PROPERTIES:\n:SECRET: never send\n:END:\n- First\nUnsupported\nSecond\n** Child\nChild secret\n* Sibling\nSibling secret\n")
      (goto-char (point-min)) (search-forward "First")
      (let ((before (buffer-string)) (position (point))
            (modified (buffer-modified-p)))
        (supertag-enrich-at-point)
        (should (equal (buffer-string) before))
        (should (= position (point)))
        (should (eq modified (buffer-modified-p)))))
    (should (equal (nreverse queries) '("First" "Unsupported" "Second")))
    (should (= 1 (length requests)))
    (let* ((request (car requests))
           (prompt (plist-get request :prompt))
           (object (json-parse-string prompt :object-type 'alist))
           (lines (alist-get 'lines object)))
      (should (= 2 (length lines)))
      (should (equal (mapcar (lambda (line) (alist-get 'line line)) lines) '(1 3)))
      (dolist (line (append lines nil))
        (let ((passages (alist-get 'passages line)))
          (should (equal (mapcar (lambda (p) (alist-get 'passage p)) passages) '(1 2)))
          (should (equal (alist-get 'text (aref passages 0))
                         (nth 2 (car supertag-enrich-test--passages))))))
      (should-not (string-match-p "Unsupported\\|secret\\|short preview" prompt))
      (should (eq :llm-query (plist-get request :type)))
      (should (eq 'none (plist-get request :tools)))
      (should-not (plist-get request :record-conversation))
      (should (= supertag-ai-timeout (plist-get request :deadline)))
      (should (equal " *supertag-ai*" (buffer-name (plist-get request :buffer))))
      (should-not (plist-member request :delivery-function))
      (should (functionp (plist-get (plist-get request :sink) :error))))))

(ert-deftest supertag-enrich-empty-retrieval-does-not-need-runtime ()
  (supertag-enrich-test-with-request
    (cl-letf (((symbol-function 'supertag-ai--ensure-runtime)
               (lambda () (ert-fail "No runtime needed for an empty retrieval"))))
      (with-temp-buffer
        (org-mode) (insert "* Unsupported\n#+KEY: ignored\n") (goto-char 1)
        (supertag-enrich-at-point)))
    ;; Neither the reading scope nor the whole library supports this title.
    (should (equal queries '("Unsupported" "Unsupported")))
    (should-not requests)
    (with-current-buffer (car previews)
      (should buffer-read-only)
      (should (string-match-p "01 LINES / 00 READY" (buffer-string)))
      (should (string-match-p "HEADING   NO SOURCE" (buffer-string)))
      (should-not (string-match-p "INSERT" (buffer-string))))))

(ert-deftest supertag-enrich-parser-drops-out-of-range-and-wrong-line-evidence ()
  (cl-multiple-value-bind (accepted dropped drops)
      (supertag-enrich--parse
       "{\"entries\":[{\"line\":1,\"text\":\"Bad\",\"passage\":3,\"quote\":\"Exact evidence.\"},{\"line\":2,\"text\":\"Bad\",\"passage\":1,\"quote\":\"Exact evidence.\"}]}"
       (supertag-enrich-test--lines))
    (should-not accepted)
    (should (= 2 dropped))
    (should (= 1 (alist-get 1 drops)))
    (should (= 1 (alist-get 2 drops)))))

(ert-deftest supertag-enrich-parser-keeps-whitespace-normalized-full-text-quote ()
  (cl-multiple-value-bind (accepted dropped)
      (supertag-enrich--parse
       "{\"entries\":[{\"line\":1,\"text\":\"Expanded\",\"passage\":1,\"quote\":\"  Whitespace  changes\\nare\\tfine. \"}]}"
       (supertag-enrich-test--lines))
    (should (equal "Expanded" (plist-get (alist-get 1 accepted) :text)))
    (should (zerop dropped))))

(ert-deftest supertag-enrich-parser-rejects-malformed-duplicate-empty-and-unknown ()
  (let* ((valid '((line . 1) (text . "Expanded") (passage . 1) (quote . "Exact evidence.")))
         (bad (list nil 42 "not an object"
                    '((line . 99) (text . "Bad") (passage . 1) (quote . "Exact evidence."))
                    '((line . 3) (text . "Bad") (passage . 1) (quote . "Exact evidence.")))))
    (dolist (pair '((passage . 0) (passage . -1) (passage . 1.0) (passage . "1")
                    (line . "1") (text . " ") (quote . "\n\t") (quote . nil)
                    (quote . "short preview") (quote . "Invented evidence")))
      (push (cons pair (assq-delete-all (car pair) (copy-tree valid))) bad))
    (cl-multiple-value-bind (accepted dropped)
        (supertag-enrich--parse
         (json-encode `((entries . ,(vconcat (append bad (list valid valid))))))
         (supertag-enrich-test--lines))
      (should (= 1 (length accepted)))
      (should (= (1+ (length bad)) dropped))))
  (dolist (text '("no json" "[]" "{}" "{\"entries\":{}}"))
    (should-error (supertag-enrich--parse text (supertag-enrich-test--lines))))
  (cl-multiple-value-bind (accepted dropped)
      (supertag-enrich--parse
       (concat "```json\n" (json-encode '((entries . [((line . 1) (text . "Expanded") (passage . 1) (quote . "Exact evidence."))]))) "\n```")
       (supertag-enrich-test--lines))
    (should (= 1 (length accepted)))
    (should (= 0 dropped))))

(ert-deftest supertag-enrich-preview-order-counts-and-public-citation-button ()
  (supertag-enrich-test-with-request
    (with-temp-buffer
      (org-mode) (insert "* Heading\nFirst\nUnsupported\nThird\n") (goto-char 1)
      (supertag-enrich-at-point))
    (supertag-enrich-test--deliver
     (car requests)
     "{\"entries\":[{\"line\":3,\"text\":\"Not kept\",\"passage\":1,\"quote\":\"Invented\"},{\"line\":1,\"text\":\"Kept expansion\",\"passage\":1,\"quote\":\"Exact evidence.\"}]}")
    (with-current-buffer (car previews)
      (should buffer-read-only)
      (should-not (buffer-modified-p))
      (should-not buffer-file-name)
      (should (string-match-p "03 LINES / 01 READY" (buffer-string)))
      (search-forward "LINE / 01   VERIFIED")
      ;; Each row is named in the gutter; only the user's own line is filled.
      (search-forward "\n ORIGIN  First\n")
      (should (memq 'supertag-view-panel
                    (ensure-list (get-text-property (- (point) 3) 'face))))
      (search-forward " ENRICH  Kept expansion\n")
      (should-not (memq 'supertag-view-panel
                        (ensure-list (get-text-property (- (point) 3) 'face))))
      (search-forward " QUOTE   “Exact evidence.”\n") (search-forward " FROM    → Book")
      (let ((button (button-at (1- (point)))))
        (should (eq 'chai-context-citation (button-type button)))
        (should (equal (button-get button 'chai-hit) (nth 1 (car supertag-enrich-test--passages))))
        (button-activate button)
        (should (equal followed (button-get button 'chai-hit))))
      (search-forward "LINE / 02   NO SOURCE") (search-forward "Unsupported")
      (search-forward "LINE / 03   REJECTED / 01") (search-forward "Third")
      (should-not (string-match-p "Not kept\\|Invented" (buffer-string)))
      (should-error (insert "Write") :type 'buffer-read-only))))

(ert-deftest supertag-enrich-request-and-delivery-never-write-org-or-store ()
  (supertag-document-test-with-vault
    (supertag-enrich-test-with-request
      (with-current-buffer (find-file-noselect plain)
        (goto-char (point-max)) (insert "Live unsaved text\n")
        (let ((before (list (buffer-string) (buffer-modified-p)
                            (supertag-document-test-disk plain)
                            (prin1-to-string supertag--store)))
              (buffer-read-only t))
          (supertag-enrich-at-point)
          (supertag-enrich-test--deliver (car requests) "{\"entries\":[]}")
          (should-not (org-entry-get nil "ID"))
          (should (equal before (list (buffer-string) (buffer-modified-p)
                                      (supertag-document-test-disk plain)
                                      (prin1-to-string supertag--store)))))))))

(ert-deftest supertag-enrich-failure-malformed-reply-and-late-delivery-stay-safe ()
  (supertag-enrich-test-with-request
    (dolist (status '(failed timed-out audit-incomplete cancelled malformed))
      (with-temp-buffer
        (org-mode) (insert "* Heading\nLine\n") (goto-char 1)
        (supertag-enrich-at-point))
      (supertag-enrich-test--deliver (car requests) "Unverified text"
                                   (unless (eq status 'malformed) status))
      (with-current-buffer (car previews)
        (should (string-match-p (if (eq status 'malformed) "Could not verify" "Request failed")
                                (buffer-string)))
        (let ((before (buffer-string)))
          (supertag-enrich-test--deliver (car requests) "{\"entries\":[]}")
          (should (equal before (buffer-string)))))
      (kill-buffer (car previews))
      (supertag-enrich-test--deliver (car requests) "{\"entries\":[]}"))))

(ert-deftest supertag-enrich-synchronous-delivery-and-independent-previews ()
  (supertag-enrich-test-with-request
    (with-temp-buffer
      (org-mode) (insert "* Heading\nLine\n") (goto-char 1)
      (cl-letf (((symbol-function 'supertag-ai--submit)
                 (lambda (request)
                   (supertag-enrich-test--deliver request "{\"entries\":[]}")
                   '(:run-id "sync"))))
        (supertag-enrich-at-point))
      (supertag-enrich-at-point))
    (should (= 2 (length previews)))
    (should-not (eq (car previews) (cadr previews)))
    (with-current-buffer (cadr previews)
      (should (string-match-p "Verification complete" (buffer-string))))
    (kill-buffer (car previews))
    (supertag-enrich-test--deliver (car requests) "{\"entries\":[]}")
    (should-not (buffer-live-p (car previews)))))

(ert-deftest supertag-enrich-submit-error-is-visible-and-does-not-write ()
  (supertag-enrich-test-with-request
    (with-temp-buffer
      (org-mode) (insert "* Heading\nLine\n") (goto-char 1)
      (let ((before (buffer-string)))
        (cl-letf (((symbol-function 'supertag-ai--submit) (lambda (_) (error "Rejected"))))
          (should-error (supertag-enrich-at-point)))
        (should (equal before (buffer-string)))))
    (with-current-buffer (car previews)
      (should (string-match-p "Request failed: Rejected" (buffer-string))))))

(ert-deftest supertag-enrich-optional-dependencies-are-guarded-and-not-required ()
  (let ((original (symbol-function 'require)))
    (cl-letf (((symbol-function 'require)
               (lambda (feature &rest args)
                 (when (string-match-p "\\`\\(?:chai\\|superchat\\)" (symbol-name feature))
                   (ert-fail "Optional package was required"))
                 (apply original feature args))))
      (load "supertag-enrich" nil t)))
  (supertag-enrich-test-with-request
    (dolist (missing '(chai-context-for chai-context-source-name chai-context-hit
                      superchat-runtime-submit superchat-sink-create))
      (with-temp-buffer
        (org-mode) (insert "* Heading\nLine\n") (goto-char 1)
        (cl-letf (((symbol-function missing) nil))
          (should (string-match-p
                   (if (string-prefix-p "chai" (symbol-name missing)) "chai-context\\.el is not on" "[Ss]uperchat")
                   (cadr (should-error (supertag-enrich-at-point) :type 'user-error)))))))
    (should-not requests)))

(ert-deftest supertag-enrich-command-rejects-non-heading-and-embark-wrapper-is-bound ()
  (with-temp-buffer
    (should-error (supertag-enrich-at-point) :type 'user-error)
    (org-mode) (insert "Preamble\n* Heading\nLine\n") (goto-char 1)
    (should-error (supertag-enrich-at-point) :type 'user-error)
    (should-error (supertag-embark-node-enrich "stale") :type 'user-error)
    (search-forward "Line")
    (let ((calls 0))
      (cl-letf (((symbol-function 'supertag-enrich-at-point) (lambda () (cl-incf calls))))
        (supertag-embark-node-enrich "ignored"))
      (should (= 1 calls))))
  (should-not (commandp 'supertag-embark-node-enrich))
  (should (eq #'supertag-embark-node-enrich (keymap-lookup supertag-embark-node-map "e"))))

(cl-defstruct supertag-enrich-test-book
  "Stand-in for the public book result, without loading Chai.
Slot order deliberately differs from chai-book; production reads named slots."
  file-path title)

(defmacro supertag-enrich-test-with-windows (files &rest body)
  "Run BODY with two windows visiting FILES in this batch Emacs only."
  (declare (indent 1))
  `(save-window-excursion
     (let ((first (generate-new-buffer " *enrich-first*"))
           (second (generate-new-buffer " *enrich-second*")))
       (unwind-protect
           (progn
             (delete-other-windows)
             (with-current-buffer first
               (org-mode) (insert "* Heading\nFirst\nSecond\n") (goto-char 1)
               (setq buffer-file-name ,(car files)))
             (with-current-buffer second
               (org-mode) (insert "* Other\nOther line\n") (goto-char 1)
               (setq buffer-file-name ,(cadr files)))
             (set-window-buffer (selected-window) first)
             (let ((other (split-window-below)))
               (set-window-buffer other second)
               ,@body))
         (dolist (buffer (list first second))
           (with-current-buffer buffer (set-buffer-modified-p nil))
           (kill-buffer buffer))))))

(ert-deftest supertag-enrich-scope-selected-window-wins-and-is-resolved-once ()
  (supertag-enrich-test-with-request
    (supertag-enrich-test-with-windows ("/tmp/first.org" "/tmp/selected.org")
      ;; Select the second window, not the frame's first window.
      (select-window other)
      (with-current-buffer second (erase-buffer) (insert "* Heading\nFirst\nUnsupported\n"))
      (let ((scans 0) looked-up calls
            (original-window-list (symbol-function 'window-list)))
        (cl-letf (((symbol-function 'window-list)
                   (lambda (frame minibuffer window)
                     (cl-incf scans)
                     (should (eq frame (selected-frame)))
                     (should (eq window other))
                     (should (eq minibuffer 'no-minibuf))
                     (funcall original-window-list frame minibuffer window)))
                  ((symbol-function 'chai-index-book-at)
                   (lambda (path)
                     (push path looked-up)
                     (make-supertag-enrich-test-book :title "Selected Book" :file-path path)))
                  ((symbol-function 'chai-context-for)
                   (lambda (query &optional filters)
                     (push (list query filters) calls)
                     (unless (equal query "Unsupported") supertag-enrich-test--passages))))
          (with-current-buffer second (goto-char 1) (supertag-enrich-at-point)))
        (should (= 1 scans))
        (should (equal looked-up '("/tmp/selected.org")))
        (should (equal (nreverse calls)
                       '(("First" (:file "/tmp/selected.org"))
                         ("Unsupported" (:file "/tmp/selected.org")))))
        (should (= 1 (length requests)))
        (should-not (string-match-p "Unsupported" (plist-get (car requests) :prompt)))
        (with-current-buffer (car previews)
          (should (string-match-p "SCOPE / SELECTED BOOK $" (buffer-string)))
          (should-not (string-match-p "^Widened:" (buffer-string))))
        ;; Changing windows or rejecting model evidence cannot widen or resolve
        ;; scope again.  The completion retains the original scope snapshot.
        (select-window (get-buffer-window first))
        (cl-letf (((symbol-function 'chai-index-book-at) (lambda (_) (ert-fail "Late scope lookup")))
                  ((symbol-function 'chai-context-for) (lambda (&rest _) (ert-fail "Late retrieval"))))
          (supertag-enrich-test--deliver
           (car requests)
           "{\"entries\":[{\"line\":1,\"text\":\"Bad\",\"passage\":1,\"quote\":\"Invented\"}]}"))
        (with-current-buffer (car previews)
          (should (string-match-p "SCOPE / SELECTED BOOK $" (buffer-string)))
          (should (string-match-p "REJECTED / 01" (buffer-string))))))))

(ert-deftest supertag-enrich-scope-first-other-book-wins-in-window-list-order ()
  (supertag-enrich-test-with-request
    (supertag-enrich-test-with-windows ("/tmp/notes.org" "/tmp/book.org")
      ;; A later window also visits a book, but must not be looked up.
      (let ((last (split-window other nil 'below)) looked-up calls)
        (set-window-buffer last second)
        (cl-letf (((symbol-function 'chai-index-book-at)
                   (lambda (path)
                     (push path looked-up)
                     (when (equal path "/tmp/book.org")
                       (make-supertag-enrich-test-book :title "Visible Book" :file-path path))))
                  ((symbol-function 'chai-context-for)
                   (lambda (query &optional filters)
                     (push (list query filters) calls)
                     supertag-enrich-test--passages)))
          (with-current-buffer first (supertag-enrich-at-point)))
        (should (equal (nreverse looked-up) '("/tmp/notes.org" "/tmp/book.org")))
        (should (equal (nreverse calls) '(("First" (:file "/tmp/book.org"))
                                        ("Second" (:file "/tmp/book.org")))))
        (with-current-buffer (car previews)
          (should (string-match-p "SCOPE / VISIBLE BOOK $" (buffer-string))))))))

(ert-deftest supertag-enrich-scope-fallback-is-heading-wide-and-previewed ()
  ;; (OPEN-BOOK WINNING-FILTER EXPECTED-LABEL FILTERS-TRIED).
  ;; Only Second is ever supported: an unsupported First must not widen alone.
  (dolist (case '((nil (:status reading) "books being read" ((:status reading)))
                  (nil nil "whole library" ((:status reading) nil))
                  (t (:status reading) "books being read" ((:file "/tmp/book.org") (:status reading)))
                  (t nil "whole library" ((:file "/tmp/book.org") (:status reading) nil))
                  (t none "whole library" ((:file "/tmp/book.org") (:status reading) nil))))
    (supertag-enrich-test-with-request
      (supertag-enrich-test-with-windows ("/tmp/book.org" "/tmp/another.org")
        (let (calls looked-up)
          (cl-letf (((symbol-function 'chai-index-book-at)
                     (lambda (path)
                       (push path looked-up)
                       (when (car case)
                         (make-supertag-enrich-test-book :title "Open Book" :file-path path))))
                    ((symbol-function 'chai-context-for)
                     (lambda (query &optional filters)
                       (push (list query filters) calls)
                       (when (and (equal query "Second") (equal filters (nth 1 case)))
                         supertag-enrich-test--passages))))
            (with-current-buffer first (supertag-enrich-at-point)))
          (should (equal (nreverse calls)
                         (cl-loop for filter in (nth 3 case)
                                  append (list (list "First" filter) (list "Second" filter)))))
          (when (car case)
            ;; Do not try the second open book after the first lacks passages.
            (should (equal looked-up '("/tmp/book.org"))))
          (unless (car case)
            (should (equal (nreverse looked-up) '("/tmp/book.org" "/tmp/another.org"))))
          (if (eq (nth 1 case) 'none)
              (should-not requests)
            (should (= 1 (length requests)))
            (let* ((object (json-parse-string (plist-get (car requests) :prompt) :object-type 'alist))
                   (sent (alist-get 'lines object)))
              (should (= 1 (length sent)))
              (should (= 2 (alist-get 'line (aref sent 0)))))
            (supertag-enrich-test--deliver (car requests) "{\"entries\":[]}"))
          (with-current-buffer (car previews)
            (should (string-match-p (concat "SCOPE / " (upcase (nth 2 case)) " $") (buffer-string)))
            (if (cdr (nth 3 case))
                (should (string-match-p "^Widened:" (buffer-string)))
              (should-not (string-match-p "^Widened:" (buffer-string))))
            (when (car case)
              (should (string-match-p "^Widened: nothing in open book “Open Book”$" (buffer-string))))
            (when (equal (nth 2 case) "whole library")
              (should (string-match-p "^Widened: nothing in books being read$" (buffer-string))))
            (when (eq (nth 1 case) 'none)
              (should (string-match-p "02 LINES / 00 READY" (buffer-string))))))))))

(ert-deftest supertag-enrich-scope-missing-book-api-starts-with-reading ()
  (supertag-enrich-test-with-request
    (supertag-enrich-test-with-windows ("/tmp/book.org" "/tmp/another.org")
      (let (filters)
        (cl-letf (((symbol-function 'chai-index-book-at) nil)
                  ((symbol-function 'window-list) (lambda (&rest _) (ert-fail "No book API; skip windows")))
                  ((symbol-function 'chai-context-for)
                   (lambda (_query &optional filter)
                     (push filter filters) supertag-enrich-test--passages)))
          (with-current-buffer first (supertag-enrich-at-point)))
        (should (equal filters '((:status reading) (:status reading))))
        (with-current-buffer (car previews)
          (should (string-match-p "SCOPE / BOOKS BEING READ $" (buffer-string))))))))

(ert-deftest supertag-enrich-scope-directory-symlink-uses-chai-indexed-path ()
  (let* ((tmp (make-temp-file "supertag-enrich-symlink-" t))
         (library (expand-file-name "library/" tmp))
         (alias (expand-file-name "alias/" tmp)))
    (unwind-protect
        (progn
          (make-directory library)
          (with-temp-file (expand-file-name "book.org" library) (insert "* Book\n"))
          (make-symbolic-link (directory-file-name library) (directory-file-name alias))
          ;; Test both an alias visit to a real-path library, and a true-path
          ;; visit when Chai itself indexed a symlinked library directory.
          (dolist (paths (list (list alias library) (list library alias)))
            (let ((visited (expand-file-name "book.org" (car paths)))
                  (indexed (expand-file-name "book.org" (cadr paths))))
              (supertag-enrich-test-with-request
                (supertag-enrich-test-with-windows (visited nil)
                  (let (looked-up filters)
                    (cl-letf (((symbol-function 'chai-index-book-at)
                               (lambda (path)
                                 (push path looked-up)
                                 ;; This mirrors the public API's directory
                                 ;; identity check and returned book path.
                                 (should (file-equal-p (file-name-directory path) (cadr paths)))
                                 (make-supertag-enrich-test-book :title "Symlink Book" :file-path indexed)))
                              ((symbol-function 'chai-context-for)
                               (lambda (_query &optional filter)
                                 (push filter filters) supertag-enrich-test--passages)))
                      (with-current-buffer first (supertag-enrich-at-point)))
                    (should (equal looked-up (list visited)))
                    (should (equal filters (list (list :file indexed) (list :file indexed))))
                    (with-current-buffer (car previews)
                      (should (string-match-p "SCOPE / SYMLINK BOOK $" (buffer-string))))))))))
      (delete-directory tmp t))))


(ert-deftest supertag-enrich-source-button-lands-on-the-quote ()
  (let* ((file (make-temp-file "book" nil ".org" "* Ch\nfirst para line.\n\nSecond one has [[chai:hl][the  key\nsentence]] here.\n"))
         (hit (list :file file :beg 6 :end 200)))
    (cl-letf (((symbol-plist 'chai-context-citation) nil))
    (define-button-type 'chai-context-citation
      'action (lambda (b) (let ((h (button-get b 'chai-hit)))
                            (set-buffer (find-file-noselect (plist-get h :file)))
                            (goto-char (plist-get h :beg)))))
    (progn
      (with-temp-buffer
        (insert-text-button "src" 'type 'chai-context-citation 'chai-hit hit
                            'supertag-enrich-quote "Second one has the key sentence here."
                            'action #'supertag-enrich--follow)
        (supertag-enrich--follow (button-at 1))
        (should (looking-at "Second one has")))
      (with-temp-buffer
        (insert-text-button "src" 'type 'chai-context-citation 'chai-hit hit
                            'supertag-enrich-quote "the key sentence"
                            'action #'supertag-enrich--follow)
        (supertag-enrich--follow (button-at 1))
        (should (looking-at "the  key\nsentence")))
      (with-temp-buffer
        (insert-text-button "src" 'type 'chai-context-citation 'chai-hit hit
                            'supertag-enrich-quote "absent words entirely"
                            'action #'supertag-enrich--follow)
        (supertag-enrich--follow (button-at 1))
        (should (= (point) 6)))))
    (delete-file file)))

;;; Linked sources and writing back

(defmacro supertag-enrich-test-with-book (&rest body)
  "Run BODY with BOOK, a source file whose line 4 starts its second paragraph."
  (declare (indent 0))
  `(let ((book (make-temp-file
                "20260101T101010__Author__Some-Book" nil ".org"
                "* Ch\nfirst para line.\n\nBefore it. Raft elects [[chai:hl][one  leader]]\nper term. After it.\n\nThird.\n")))
     (unwind-protect (progn ,@body) (delete-file book))))

(ert-deftest supertag-enrich-linked-line-shows-its-paragraph-without-retrieval ()
  (supertag-enrich-test-with-book
    (supertag-enrich-test-with-request
      (cl-letf (((symbol-function 'supertag-enrich--ensure-chai)
                 (lambda () (ert-fail "Linked lines need no Chai")))
                ((symbol-function 'supertag-ai--ensure-runtime)
                 (lambda () (ert-fail "Linked lines need no model"))))
        (with-temp-buffer
          (org-mode)
          (insert (format "* Notes\n- one leader [[file:%s::4][L4]]\n" book))
          (goto-char 1)
          (supertag-enrich-at-point)))
      (should-not queries)
      (should-not requests)
      (with-current-buffer (car previews)
        (should (string-match-p "01 LINES / 01 READY" (buffer-string)))
        (should (string-match-p "SCOPE / LINKED SOURCES" (buffer-string)))
        (search-forward "LINE / 01   LINKED")
        (search-forward " ORIGIN  one leader L4\n")
        (search-forward " ENRICH  Before it. Raft elects ")
        ;; The words the note already holds stand out from their context.
        (should (eq 'supertag-view-accent (get-text-property (point) 'face)))
        (should (eq 'supertag-view-excerpt (get-text-property (- (point) 3) 'face)))
        (should (looking-at "one leader per term. After it."))
        (should-not (string-match-p "first para\\|Third" (buffer-string)))
        (search-forward "› L4")
        (let ((buffer (current-buffer)))
          (unwind-protect
              (progn
                (push-button (1- (point)))
                (should (file-equal-p buffer-file-name book))
                (should (looking-at "one  leader")))
            (when (file-equal-p (or buffer-file-name "") book) (kill-buffer))
            (set-buffer buffer)))))))

(ert-deftest supertag-enrich-heading-source-is-a-unit-and-the-first-scope ()
  (supertag-enrich-test-with-book
    (supertag-enrich-test-with-request
      (let (calls)
        (cl-letf (((symbol-function 'chai-context-for)
                   (lambda (query &optional filters)
                     (push (list query filters) calls)
                     supertag-enrich-test--passages)))
          (with-temp-buffer
            (org-mode)
            (insert (format "* [KEY] Raft elects one leader\n:PROPERTIES:\n:SOURCE: [[file:%s::4][L4]]\n:END:\nMy comment\n" book))
            (goto-char 1)
            (supertag-enrich-at-point)))
        (should (equal calls `(("My comment" (:file ,book)))))
        ;; The comment keeps its unit number in the request.
        (should (string-match-p "\"line\":2" (plist-get (car requests) :prompt)))
        (with-current-buffer (car previews)
          (should (string-match-p "SCOPE / SOME BOOK[[:alnum:]]* $" (buffer-string)))
          (search-forward "HEADING   LINKED")
          (search-forward "[ INSERT ]")
          (should-not (looking-at "  \\[ REPLACE \\]"))
          (search-forward "LINE / 02   WAITING"))))))

(ert-deftest supertag-enrich-unreadable-link-falls-back-to-retrieval ()
  (supertag-enrich-test-with-request
    (with-temp-buffer
      (org-mode)
      (insert "* Notes\nGone [[file:/nonexistent/book.org::4][L4]]\nBeyond [[chai:20200101T000000::999][L999]]\n")
      (goto-char 1)
      (supertag-enrich-at-point))
    (should (equal (nreverse queries) '("Gone L4" "Beyond L999")))))

(defmacro supertag-enrich-test-with-review (org &rest body)
  "Run BODY in the review of ORG text, with NOTES bound to its Org buffer.
Line 1 of the reply expands the first unit from the first test passage."
  (declare (indent 1))
  `(supertag-enrich-test-with-request
     (with-temp-buffer
       (org-mode) (insert ,org) (goto-char 1)
       (set-buffer-modified-p nil)
       (let ((notes (current-buffer)))
         (supertag-enrich-at-point)
         (when requests
           (supertag-enrich-test--deliver
            (car requests)
            "{\"entries\":[{\"line\":1,\"text\":\"Kept\\nexpansion\",\"passage\":1,\"quote\":\"Exact evidence.\"}]}"))
         (with-current-buffer (car previews)
           (goto-char (text-property-any (point-min) (point-max) 'supertag-enrich-unit 1))
           ,@body)))))

(ert-deftest supertag-enrich-insert-goes-below-the-line-inside-its-item ()
  (supertag-enrich-test-with-review "* H\n  - [ ] First\n  - Unsupported\n"
    (supertag-enrich-insert)
    (should (equal (with-current-buffer notes (buffer-string))
                   "* H\n  - [ ] First\n    Kept\nexpansion\n  - Unsupported\n"))
    (should (string-match-p "LINE / 01   INSERTED" (buffer-string)))
    (should-not (string-match-p "\\[ INSERT" (buffer-string)))
    (should-error (supertag-enrich-insert) :type 'user-error)
    (should-error (supertag-enrich-replace) :type 'user-error)
    (supertag-enrich-next)
    (should-error (supertag-enrich-insert) :type 'user-error)
    (should-not (with-current-buffer notes buffer-file-name))))

(ert-deftest supertag-enrich-replace-keeps-indent-bullet-and-checkbox ()
  (supertag-enrich-test-with-review "* H\n  1. [X] First\nSecond\n"
    (search-forward "[ REPLACE ]")
    (push-button (1- (point)))
    (should (equal (with-current-buffer notes (buffer-string))
                   "* H\n  1. [X] Kept\nexpansion\nSecond\n"))
    (should (string-match-p "LINE / 01   REPLACED" (buffer-string)))))

(ert-deftest supertag-enrich-write-refuses-a-line-that-changed ()
  (supertag-enrich-test-with-review "* H\nFirst\n"
    (with-current-buffer notes
      (goto-char (point-min)) (search-forward "First") (insert " edited"))
    (supertag-enrich-insert)
    (should (equal (with-current-buffer notes (buffer-string)) "* H\nFirst edited\n"))
    (should (string-match-p "LINE / 01   STALE" (buffer-string)))))

(ert-deftest supertag-enrich-insert-follows-a-line-that-moved ()
  (supertag-enrich-test-with-review "* H\nFirst\n"
    (with-current-buffer notes
      (goto-char (point-min)) (forward-line 1) (insert "Earlier\n"))
    (supertag-enrich-insert)
    (should (equal (with-current-buffer notes (buffer-string))
                   "* H\nEarlier\nFirst\nKept\nexpansion\n"))))

(ert-deftest supertag-enrich-insert-all-confirms-once-and-writes-source-links ()
  (supertag-enrich-test-with-book
    (let ((asked 0))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) (cl-incf asked) t)))
        (supertag-enrich-test-with-review
            (format "* Raft elects\n:PROPERTIES:\n:SOURCE: [[file:%s::4][L4]]\n:END:\n- third [[file:%s::7][L7]]\n\n** Child\n" book book)
          (search-backward "[ INSERT ALL ]")
          (push-button (point))
          (should (= 1 asked))
          (should (equal (with-current-buffer notes (buffer-string))
                         (format "* Raft elects\n:PROPERTIES:\n:SOURCE: [[file:%s::4][L4]]\n:END:\nBefore it. Raft elects one leader per term. After it. [[file:%s::4][L4]]\n- third [[file:%s::7][L7]]\n  Third. [[file:%s::7][L7]]\n\n** Child\n"
                                 book book book book)))
          (should-not (string-match-p "INSERT ALL" (buffer-string)))
          (should-error (supertag-enrich-insert-all) :type 'user-error))))))

(ert-deftest supertag-enrich-verified-text-carries-a-chai-style-link ()
  (supertag-enrich-test-with-book
    (should (equal (supertag-enrich--hit-link (list :file book :beg 30))
                   "[[chai:20260101T101010::4][L4]]"))
    (should-not (supertag-enrich--hit-link '(:file "/nonexistent/book.org" :beg 3)))
    (should-not (supertag-enrich--hit-link '(:title "No file")))))

(ert-deftest supertag-enrich-long-source-paragraph-is-cut-near-the-line ()
  (let ((file (make-temp-file "long" nil ".org"
                              (concat (mapconcat (lambda (n) (format "line %03d of a transcript without blank lines" n))
                                                 (number-sequence 1 80) "\n")
                                      "\n"))))
    (unwind-protect
        (let ((text (supertag-enrich--source-text file 40)))
          (should (string-prefix-p "… " text))
          (should (string-suffix-p " …" text))
          (should (string-match-p "line 040" text))
          (should (< (length text) 1500))
          (should-not (supertag-enrich--source-text file 999)))
      (delete-file file))))

(ert-deftest supertag-enrich-source-text-leaves-out-the-readers-own-comments ()
  (let ((file (make-temp-file "commented" nil ".org"
                              "Intro.\n\nThe source says this.\n#+BEGIN_CHAI_COMMENT\nMy remark\n#+END_CHAI_COMMENT\nAnd continues.\n\n#+begin_chai_comment\nLoose remark\n#+end_chai_comment\n")))
    (unwind-protect
        (progn
          (dolist (line '(3 4 5 6 7))
            (should (equal (supertag-enrich--source-text file line)
                           "The source says this. And continues.")))
          ;; A comment set apart by blank lines stands for the text above it.
          (should (equal (supertag-enrich--source-text file 10)
                         "The source says this. And continues.")))
      (delete-file file))))

(ert-deftest supertag-enrich-review-is-a-modal-free-view-that-fits-its-width ()
  (should (eq 'motion (alist-get 'supertag-enrich-mode
                                 (bound-and-true-p meow-mode-state-list) 'motion)))
  (supertag-enrich-test-with-book
    (dolist (width '(120 80 40))
      (let ((fill-column width))
        (supertag-enrich-test-with-review
            (format "* A fairly long heading title for the review masthead\n%s\n- cited [[file:%s::4][L4]]\n"
                    (make-string 200 ?字) book)
          (should (derived-mode-p 'supertag-enrich-mode))
          (dolist (line (split-string (buffer-string) "\n"))
            (should (<= (string-width line) width))))))))

;;; enrich-test.el ends here
