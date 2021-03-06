;;;;  -*- Mode: Lisp; Syntax: Common-Lisp; Package: SYSTEM -*-
;;;;
;;;;  Copyright (c) 1984, Taiichi Yuasa and Masami Hagiya.
;;;;  Copyright (c) 1990, Giuseppe Attardi.
;;;;  Copyright (c) 2012, Jean-Claude Beaudoin.
;;;;
;;;;    This program is free software; you can redistribute it and/or
;;;;    modify it under the terms of the GNU Lesser General Public
;;;;    License as published by the Free Software Foundation; either
;;;;    version 3 of the License, or (at your option) any later version.
;;;;
;;;;    See file '../../Copyright' for full details.

;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;


(defun do-time (closure)
  (let* (real-start
	 run-start
	 consed-start
	 gc-no-start
	 real-end
	 run-end
	 consed-end
	 gc-no-end)
    ;; Garbage collection forces the value of counters to be updated
    (si::gc t)
    (multiple-value-setq (consed-start gc-no-start) (gc-stats t))
    (setq real-start (get-internal-real-time)
	  run-start (get-internal-run-time))
    (multiple-value-prog1
     (funcall closure)
     (setq run-end (get-internal-run-time)
	   real-end (get-internal-real-time))
     ;; Garbage collection forces the value of counters to be updated
     (si::gc t)
     (multiple-value-setq (consed-end gc-no-end) (gc-stats nil))
     (fresh-line *trace-output*)
     (format *trace-output*
             "real time : ~,3F secs~%~
              run time  : ~,3F secs~%~
              gc count  : ~D times~%~
              consed    : ~D bytes~%"
	     (/ (- real-end real-start) internal-time-units-per-second)
	     (/ (- run-end run-start) internal-time-units-per-second)
	     (max 0 (- gc-no-end gc-no-start 1)) ;; we artificially forced one.
	     (- consed-end consed-start)))))

(defmacro time (form)
  "Syntax: (time form)
Evaluates FORM, outputs the realtime and runtime used for the evaluation to
*TRACE-OUTPUT*, and then returns all values of FORM."
  `(do-time #'(lambda () ,form)))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;;
;;;;


(defun leap-year-p (y)
  (and (zerop (mod y 4))
       (or (not (zerop (mod y 100))) (zerop (mod y 400)))))

(defun number-of-days-from-1900 (y)
  (let ((y1 (1- y)))
    (+ (* (- y 1900) 365)
       (floor y1 4) (- (floor y1 100)) (floor y1 400)
       -460)))

(defconstant month-startdays #(0 31 59 90 120 151 181 212 243 273 304 334 365))

#|
;; Moved to time.d on 2012/04/12. JCB

#-mkcl-min
(ffi:clines "
#include <time.h>
")

#-mkcl-min
(defun get-local-time-zone ()
  "Returns the number of hours West of Greenwich for the local time zone."
  (ffi::c-inline () () :object "
{
  mkcl_word mw;
  struct tm ltm, gtm;
  time_t when = 0L;

  ltm = *localtime(&when);
  gtm = *gmtime(&when);

  mw = (gtm.tm_min + 60 * gtm.tm_hour) - (ltm.tm_min + 60 * ltm.tm_hour);

  if ((gtm.tm_wday + 1) % 7 == ltm.tm_wday)
    mw -= 24*60;
  else if (gtm.tm_wday == (ltm.tm_wday + 1) % 7)
    mw += 24*60;

  @(return) = mkcl_make_ratio(env, MKCL_MAKE_FIXNUM(mw),MKCL_MAKE_FIXNUM(60));
}"
		 :one-liner nil))
|#

(defun recode-universal-time (sec min hour day month year tz dst)
  (let ((days (+ (if (and (leap-year-p year) (> month 2)) 1 0)
		 (1- day)
		 (svref month-startdays (1- month))
		 (number-of-days-from-1900 year))))
    (+ sec (* 60 (+ min (* 60 (+ tz dst hour (* 24 days))))))))

(defun decode-universal-time (orig-ut &optional (tz nil tz-p) &aux (dstp nil))
  "Args: (integer &optional (timezone (si::get-local-time-zone)))
Returns as nine values the day-and-time represented by INTEGER.  See GET-
DECODED-TIME."
(loop
  (let* ((ut orig-ut) sec min hour day month year dow days)
    (unless tz-p
      (setq tz (get-local-time-zone)))
    (decf ut (round (* (+ tz (if dstp -1 0)) 3600)))
    (multiple-value-setq (ut sec) (floor ut 60))
    (multiple-value-setq (ut min) (floor ut 60))
    (multiple-value-setq (days hour) (floor ut 24))
    (setq dow (mod days 7))
    (setq year (+ 1900 (floor days 366))) ; Guess!
    (do ((x))
        ((< (setq x (- days (number-of-days-from-1900 year)))
            (if (leap-year-p year) 366 365))
         (setq day (1+ x)))
      (incf year))
    (when (leap-year-p year)
      (cond ((= day 60) (setf month 2 day 29))
	    ((> day 60) (decf day))))
    (unless month
      (setq month (position day month-startdays :test #'<=)
	    day (- day (svref month-startdays (1- month)))))
    (if (and (not tz-p) (daylight-saving-time-p orig-ut year))
	(setf tz-p t dstp t)
	(return (values sec min hour day month year dow dstp tz))))))

(defun encode-universal-time (sec min hour day month year &optional tz)
  "Args: (second minute hour date month year
       &optional (timezone (si::get-local-time-zone)))
Returns an integer that represents the given day-and-time.  See
GET-DECODED-TIME."
  (when (<= 0 year 99)
    ;; adjust to year in the century within 50 years of this year
    (multiple-value-bind (sec min hour day month this-year dow dstp tz)
	(get-decoded-time)
      (declare (ignore sec min hour day month dow dstp tz))
      (incf year (* 100 (ceiling (- this-year year 50) 100)))))
  (let ((dst 0))
    (unless tz
      (setq tz (rational (get-local-time-zone)))
      (when (daylight-saving-time-p (recode-universal-time sec min hour day month year tz -1) year)
	;; assume DST applies, and check if at corresponging UT it applies.
	;; There is an ambiguity between midnight and 1 o'clock on the day
	;; when time reverts from DST to solar:
	;; 12:01 on that day could be either 11:01 UT (before the switch) or
	;; 12:01 UT (after the switch). We opt for the former.
	(setf dst -1)))
    (recode-universal-time sec min hour day month year tz dst)))


#-mkcl-min
(ffi:clines "
#include <time.h>
") ;; required to support the ffi::c-inline in the following function.

(defun daylight-saving-time-p (universal-time year)
  "Returns T if Daylight Saving Time applies to the local time zone at
Universal Time UT, which defaults to the current time."

  ;; Some systems cannot deal with dates before 1-1-1970 and no POSIX (this is probably false on 64 bits systems, JCB)
  ;; system will be able to handle dates beyond 2038. We must
  ;; therefore restrict the time to the interval that can handled by
  ;; the timezone database.
  (let* ((utc-1-1-1970 2208988800)
	 (unix-time (- universal-time utc-1-1-1970)))
    (cond ((minusp unix-time)
	   ;; For dates before 1970 we shift to 1980/81 to guess the daylight
	   ;; saving times.
	   (setf unix-time
		 (+ (if (leap-year-p year)
			#.(encode-universal-time 0 0 0 1 1 1980 0)
			#.(encode-universal-time 0 0 0 1 1 1981 0))
		    (- universal-time (encode-universal-time 0 0 0 1 1 year 0) utc-1-1-1970))))
	  ((not (fixnump unix-time))
	   ;; Same if date is too big: we shift to year 2035/36, like SBCL does.
	   (setf unix-time
		 (+ (if (leap-year-p year)
			#.(encode-universal-time 0 0 0 1 1 2032 0)
			#.(encode-universal-time 0 0 0 1 1 2033 0))
		    (- universal-time (encode-universal-time 0 0 0 1 1 year 0) utc-1-1-1970)))))
    #+mkcl-min nil
    #-mkcl-min
    (ffi::c-inline (unix-time) (:unsigned-long) :bool "
{
	time_t when = (#0);
	struct tm *ltm = localtime(&when);
	@(return) = ltm->tm_isdst;
}"
		 :one-liner nil)))

(defun get-decoded-time ()
  "Args: ()
Returns the current day-and-time as nine values:
	second (0 - 59)
	minute (0 - 59)
	hour (0 - 23)
	date (1 - 31)
	month (1 - 12)
	year (Christian, not Japanese long-live-Emperor)
	day of week (0 for Mon, .. 6 for Sun)
	summer time or not (T or NIL)
	time zone (-9 in Japan)
Sunday is the *last* day of the week!!"
  (decode-universal-time (get-universal-time)))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;;
;;;;


(defmacro with-hash-table-iterator ((iterator package) &body body)
"Syntax: (with-hash-table-iterator (iterator package) &body body)
Loop over the elements of a hash table. ITERATOR is a lexically bound function
that outputs three values
	(VALUES entry-p key value)
ENTRY-P is true only if KEY and VALUE denote a pair of key and value of the
hash table; otherwise it signals that we have reached the end of the hash table."
  `(let ((,iterator (hash-table-iterator ,package)))
    (macrolet ((,iterator () (list 'funcall ',iterator)))
      ,@body)))

(defun sharp-!-reader (stream subchar arg)
  (declare (ignore subchar arg))
  (read-line stream)
  (values))

(set-dispatch-macro-character #\# #\! 'sharp-!-reader)

(defun si::simple-program-error (message &rest datum)
  ;;(apply #'error 'simple-program-error :format-control message :format-arguments (car datum) (cdr datum))
  (error 'simple-program-error :format-control message :format-arguments datum)
  )



#|
(defun room-report (label)
  (print label) (terpri)
  (dolist (item (si:sample-allocation-statistics))
    (princ #\tab) (princ (car item)) (princ ": ") (princ (cdr item)) (terpri)
    )
  )
|#

