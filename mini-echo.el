;;; mini-echo.el --- Echo buffer status in minibuffer window -*- lexical-binding: t -*-

;; Copyright (C) 2023, 2024 liuyinz

;; Author: liuyinz <liuyinz95@gmail.com>
;; Maintainer: liuyinz <liuyinz95@gmail.com>
;; Version: 0.13.0
;; Package-Requires: ((emacs "29.1") (dash "2.19.1") (hide-mode-line "1.0.3"))
;; Keywords: frames
;; Homepage: https://github.com/liuyinz/mini-echo.el

;; This file is not a part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;; This file is not a part of GNU Emacs.

;;; Commentary:

;; Echo buffer status in minibuffer window

;;; Code:

(eval-when-compile
  (require 'eieio))

(require 'cl-lib)
(require 'subr-x)
(require 'face-remap)
(require 'pcase)
(require 'map)

(require 'dash)
(require 'hide-mode-line)

(require 'mini-echo-segments)

(make-obsolete-variable 'mini-echo-default-segments
                        'mini-echo-persistent-rules "0.13.0")

(defgroup mini-echo nil
  "Echo buffer status in minibuffer window."
  :group 'mini-echo)

(defcustom mini-echo-persistent-rules
  '(:long ("major-mode" "shrink-path" "vcs" "buffer-position" "buffer-size" "flymake")
    :short ("buffer-name" "buffer-position" "flymake"))
  "Plist of segments which are persistent for buffers.
Used as fallback if `mini-echo-persistent-function' return nil."
  :type '(plist :key-type symbol
                :options '(:long :short :both)
                :value-type (repeat string))
  :package-version '(mini-echo . "0.13.0")
  :group 'mini-echo)

(defcustom mini-echo-temporary-rules
  '(:both ("process" "selection-info" "narrow" "macro"
           "profiler" "repeat" "blame" "text-scale"))
  "Plist of segments which are temporary for buffers.
These segments are triggered by commands usually."
  :type '(plist :key-type symbol
                :options '(:long :short :both)
                :value-type (repeat string))
  :package-version '(mini-echo . "0.13.0")
  :group 'mini-echo)

(defcustom mini-echo-persistent-function
  #'mini-echo-persistent-detect
  "Function to fetch persistent rule conditionally.
Return a plist of (:both SEGMENTS..) or (:long SEGMENTS.. :short SEGMENTS..)
when matched, otherwise return nil and use `mini-echo-persistent-rules'
as fallback."
  :type '(choice (const :tag "fetch rule when matched"
                        mini-echo-persistent-detect)
                 function)
  :package-version '(mini-echo . "0.13.0")
  :group 'mini-echo)

(defcustom mini-echo-short-style-predicate
  #'mini-echo-minibuffer-width-lessp
  "Predicate to select segments in short style."
  :type '(choice (const :tag "default predicate function"
                        mini-echo-minibuffer-width-lessp)
                 function)
  :package-version '(mini-echo . "0.5.1")
  :group 'mini-echo)

(defcustom mini-echo-separator " "
  "String separator for mini echo segments info."
  :type 'string
  :package-version '(mini-echo . "0.5.0")
  :group 'mini-echo)

(defcustom mini-echo-ellipsis ".."
  "String used to abbreviate text in segments info."
  :type 'string
  :package-version '(mini-echo . "0.5.2")
  :group 'mini-echo)

(defcustom mini-echo-right-padding 0
  "Padding to append after mini echo info.
Set this to avoid truncation."
  :type 'number
  :group 'mini-echo)

(defcustom mini-echo-update-interval 0.3
  "Seconds between update mini echo segments."
  :type 'number
  :group 'mini-echo)

(defcustom mini-echo-window-divider-args '(t 1 1)
  "List of arguments to initialize command `window-divider-mode'.
Format is a list of three argument:
  (`window-divider-default-places'
   `window-divider-default-right-width'
   `window-divider-default-bottom-width')."
  :type '(symbol number number)
  :group 'mini-echo)

(defface mini-echo-minibuffer-window
  '((t :inherit default))
  "Face used to highlight the minibuffer window.")

(defconst mini-echo-modified-buffers
  '(" *Echo Area 0*" " *Echo Area 1*" " *Minibuf-0*"))

(defvar mini-echo-overlays nil)
(defvar-local mini-echo--remap-cookie nil)
(defvar mini-echo--valid-segments nil)
(defvar mini-echo--default-rule nil)
(defvar-local mini-echo--selected-rule nil)
(defvar mini-echo--toggled-segments nil)
(defvar mini-echo--info-last-built nil)


;;; Segments functions

(defun mini-echo-segment-valid-p (segment)
  "Return non-nil if SEGMENT is valid."
  (member segment mini-echo--valid-segments))

(defun mini-echo-normalize-rule (rule)
  "Return a plist of (:long ... :short ...) according to RULE."
  (let* ((valid-rule (--map-when (not (keywordp it))
                                 (-filter #'mini-echo-segment-valid-p it)
                                 rule))
         (use-both (memq :both valid-rule)))
    (list :long (plist-get valid-rule (or (and use-both :both) :long))
          :short (plist-get valid-rule (or (and use-both :both) :short)))))

(defun mini-echo-merge-rules (persistent)
  "Merge PERSISTENT with `mini-echo-temporary-rules' and return the result."
  (map-merge-with
   'plist
   (lambda (v1 v2) (append v1 v2))
   (mini-echo-normalize-rule persistent)
   (mini-echo-normalize-rule mini-echo-temporary-rules)))

(defun mini-echo-persistent-detect ()
  "Return a plist of persistent rule if matched.
Otherwise, return nil."
  (with-current-buffer (current-buffer)
    ;; NOTE return the first match, so the former has higher priority
    (pcase major-mode
      ((guard (bound-and-true-p atomic-chrome-edit-mode))
       '(:both ("atomic-chrome" "buffer-name" "buffer-position" "flymake")))
      ((guard (or (memq major-mode '(git-commit-elisp-text-mode git-rebase-mode))
                  (string-match-p "\\`magit-.*-mode\\'" (symbol-name major-mode))))
       '(:both ("major-mode" "project")))
      ('ibuffer-mode '(:both "major-mode"))
      ('diff-mode '(:both ("major-mode")))
      ('dired-mode '(:both ("major-mode" "dired")))
      ('helpful-mode '(:both ("major-mode" "helpful")))
      ('xwidget-webkit-mode '(:long ("shrink-path") :short ("buffer-name")))
      ((or 'vterm-mode 'quickrun--mode 'inferior-python-mode
           'nodejs-repl-mode 'inferior-emacs-lisp-mode)
       '(:both ("ide")))
      (_ nil))))

(defun mini-echo-ensure ()
  "Ensure all predefined variable ready for mini echo."
  (setq mini-echo--valid-segments (-map #'car mini-echo-segment-alist))
  (setq mini-echo--default-rule
        (mini-echo-merge-rules mini-echo-persistent-rules)))

(defun mini-echo-get-segments (target)
  "Return list of segments according to TARGET."
  (pcase target
    ('selected
     (with-memoization mini-echo--selected-rule
       (or (when-let ((rule (funcall mini-echo-persistent-function)))
             (mini-echo-merge-rules rule))
           mini-echo--default-rule)))
    ('current
     (let ((result (plist-get (mini-echo-get-segments 'selected)
                              (if (funcall mini-echo-short-style-predicate)
                                  :short :long)))
           extra)
       (--each mini-echo--toggled-segments
         (-let [(segment . enable) it]
           (if enable
               (unless (member segment result)
                 (push segment extra))
             (setq result (remove segment result)))))
       (-concat result extra)))
    ;; FIXME only filter persistent segments
    ('no-current (-difference mini-echo--valid-segments
                              (mini-echo-get-segments 'current)))
    ('toggle (cl-remove-duplicates
              (-concat (-map #'car mini-echo--toggled-segments)
                       (mini-echo-get-segments 'current)
                       (mini-echo-get-segments 'no-current))
              :test #'equal
              :from-end t))))

(defun mini-echo-concat-segments ()
  "Return concatenated information of selected segments."
  (-> (->> (mini-echo-get-segments 'current)
           (--map (with-slots (activate setup fetch update)
                      (alist-get it mini-echo-segment-alist nil nil #'string=)
                    (unless activate
                      (setq activate t)
                      (and setup (funcall setup))
                      (and update (funcall update)))
                    (funcall fetch)))
           (--filter (> (length it) 0))
           (reverse))
      (string-join mini-echo-separator)))

(defun mini-echo--toggle-completion ()
  "Return completion table for command mini echo toggle."
  (lambda (string pred action)
    (if (eq action 'metadata)
        `(metadata (display-sort-function . ,#'identity))
      (complete-with-action
       action
       (let ((current (mini-echo-get-segments 'current)))
         (--map (propertize it 'face (if (member it current) 'success 'error))
                (mini-echo-get-segments 'toggle)))
       string pred))))


;;; Ui painting

(defun mini-echo-hide-mode-line (&optional show)
  "Hide or show mode line when toggle mini-echo.
If optional arg SHOW is non-nil, show the mode line."
  (if show
      (global-hide-mode-line-mode -1)
    (setq hide-mode-line-excluded-modes nil)
    (global-hide-mode-line-mode 1)
    ;; HACK in some older emacs versions, global-hide-mode-line-mode may fails in some
    ;; fundamental-mode buffers, so add a timer to force manually
    (when (< emacs-major-version 31)
      (run-with-timer
       5 nil
       (lambda () (when-let ((bufs (--remove (buffer-local-value 'hide-mode-line-mode it)
                                             (buffer-list))))
                    (--each bufs (with-current-buffer it (hide-mode-line-mode 1)))))))))

(defun mini-echo-show-divider (&optional hide)
  "Show window divider when enable mini echo.
If optional arg HIDE is non-nil, disable the mode instead."
  (if hide
      (window-divider-mode -1)
    (-let [(window-divider-default-places
            window-divider-default-right-width
            window-divider-default-bottom-width)
           mini-echo-window-divider-args]
      (window-divider-mode 1))))

(defun mini-echo-fontify-minibuffer-window ()
  "Fontify whole window with user defined face attributes."
  (face-remap-add-relative 'default 'mini-echo-minibuffer-window))

(defun mini-echo-init-echo-area (&optional deinit)
  "Initialize echo area and minibuffer in mini echo.
If optional arg DEINIT is non-nil, remove all overlays."
  ;; delete old overlays by default
  (-each mini-echo-overlays #'delete-overlay)
  (setq mini-echo-overlays nil)
  (if deinit
      (progn
        (--each mini-echo-modified-buffers
          (with-current-buffer (get-buffer-create it)
            (when (minibufferp) (delete-minibuffer-contents))
            (face-remap-remove-relative mini-echo--remap-cookie)
            (setq-local mini-echo--remap-cookie nil)))
        (cancel-function-timers #'mini-echo-update)
        (advice-remove 'message #'mini-echo-update-overlays-before-message)
        (remove-hook 'window-size-change-functions #'mini-echo-update-overlays-when-resized)
        (remove-hook 'minibuffer-inactive-mode-hook #'mini-echo-fontify-minibuffer-window)
        (remove-hook 'minibuffer-setup-hook #'mini-echo-fontify-minibuffer-window))
    (--each mini-echo-modified-buffers
      (with-current-buffer (get-buffer-create it)
        (and (minibufferp) (= (buffer-size) 0) (insert " "))
        (push (make-overlay (point-min) (point-max) nil nil t)
              mini-echo-overlays)
        (setq-local mini-echo--remap-cookie
                    (mini-echo-fontify-minibuffer-window))))
    ;; FIXME sometimes update twice when switch from echo to minibuf
    (run-with-timer 0 mini-echo-update-interval #'mini-echo-update)
    (advice-add 'message :before #'mini-echo-update-overlays-before-message)
    (add-hook 'window-size-change-functions #'mini-echo-update-overlays-when-resized)
    ;; NOTE every time activating minibuffer would reset face,
    ;; so re-fontify when entering inactive-minibuffer-mode
    (add-hook 'minibuffer-inactive-mode-hook #'mini-echo-fontify-minibuffer-window)
    (add-hook 'minibuffer-setup-hook #'mini-echo-fontify-minibuffer-window)))

(defun mini-echo-minibuffer-width ()
  "Return width of minibuffer window in current non-child frame."
  (with-selected-frame (or (frame-parent (window-frame))
                           (window-frame))
    (window-width (minibuffer-window))))

(defun mini-echo-minibuffer-width-lessp ()
  "Return non-nil if current minibuffer window width less than 120."
  (< (mini-echo-minibuffer-width) 120))

(defun mini-echo-calculate-length (str)
  "Return length of STR.
On the gui, calculate length based on pixel, otherwise based on char."
  (if (display-graphic-p)
      (unwind-protect
          (ceiling (/ (string-pixel-width str) (float (frame-char-width))))
        (and-let* ((buf (get-buffer " *string-pixel-width*")))
          (kill-buffer buf)))
    (string-width str)))

(defun mini-echo-build-info ()
  "Build mini-echo information."
  (condition-case nil
      (if-let* ((win (get-buffer-window))
                ((window-live-p win)))
          (let* ((combined (mini-echo-concat-segments))
                 (padding (+ mini-echo-right-padding
                             (mini-echo-calculate-length combined)))
                 (prop `(space :align-to (- right-fringe ,padding))))
            (setq mini-echo--info-last-built
                  (concat (propertize " " 'cursor 1 'display prop) combined)))
        mini-echo--info-last-built)
    (format "mini-echo info building error")))

(defun mini-echo-update-overlays (&optional msg)
  "Update mini echo info in overlays according to MSG.
If MSG is nil, then use `current-message' instead."
  (when-let* (((not (active-minibuffer-window)))
              (msg (or msg (current-message) ""))
              (info (mini-echo-build-info)))
    (--each mini-echo-overlays
      (overlay-put it 'after-string
                   (if (or (equal (buffer-name (overlay-buffer it))
                                  " *Minibuf-0*")
                           (> (- (mini-echo-minibuffer-width)
                                 (string-width info)
                                 (string-width msg))
                              0))
                       info "")))))

(defun mini-echo-update-overlays-before-message (&rest args)
  "Update mini echo info before print message.
ARGS is optional."
  (mini-echo-update-overlays (and (car args) (apply #'format-message args))))

(defun mini-echo-update-overlays-when-resized (&rest _)
  "Update mini echo info after resize frame size."
  (mini-echo-update-overlays))

(defun mini-echo-update ()
  "Update mini echo info in minibuf and echo area."
  (unless (active-minibuffer-window)
    ;; update echo area overlays after-string only if it's not empty
    (--each-while mini-echo-overlays
        (not (string-empty-p (overlay-get it 'after-string)))
      (overlay-put it 'after-string (mini-echo-build-info)))))


;;; Commands

;;;###autoload
(defun mini-echo-toggle (&optional reset)
  "Enable or disable selected segment temporarily.
If optional arg RESET is non-nil, clear all toggled segments."
  (interactive "P")
  (if (bound-and-true-p mini-echo-mode)
      (if reset
          (progn
            (setq mini-echo--toggled-segments nil)
            (message "Mini-echo-toggle: reset to default."))
        (when-let ((segment (completing-read
                             "Mini-echo toggle: "
                             (mini-echo--toggle-completion) nil t)))

          (setf (alist-get segment mini-echo--toggled-segments nil nil #'string=)
                (let ((val (alist-get segment mini-echo--toggled-segments 'non-exist)))
                  (not (if (eq 'non-exist val)
                           (member segment (mini-echo-get-segments 'current))
                         val))))))
    (user-error "Please enable mini-echo-mode first")))


;;; Minor mode

;;;###autoload
(define-minor-mode mini-echo-mode
  "Minor mode to show buffer status in echo area."
  :group 'mini-echo
  :global t
  (if mini-echo-mode
      (progn
        (mini-echo-ensure)
        (mini-echo-hide-mode-line)
        (mini-echo-show-divider)
        (mini-echo-init-echo-area))
    (mini-echo-hide-mode-line 'show)
    (mini-echo-show-divider 'hide)
    (mini-echo-init-echo-area 'deinit)))

(provide 'mini-echo)
;;; mini-echo.el ends here
