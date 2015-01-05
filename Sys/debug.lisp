;;;;	-------------------------------
;;;;	Copyright (c) Corman Technologies Inc.
;;;;	See LICENSE.txt for license information.
;;;;	-------------------------------
;;;;
;;;;	File:		debug.lisp
;;;;	Contents:	debug functions for Corman Lisp.
;;;;	History:	5/6/98  RGC
;;;;

(defpackage "DEBUG"
;	(:import 
;		pl::peek-byte
;		pl::peek-dword)
	(:export 
		"FIND-SOURCE" 
		"DUMP-BYTES" 
		"DUMP-DWORDS"
		"PEEK-BYTE"
		"PEEK-DWORD"
		"DUMP-ERROR-STACK"
		"DISASSEMBLE-BYTES" 
		"CONS-ADDRESS" 
		"UVECTOR-ADDRESS"
		"*DUMP-BYTES-DEFAULT-LENGTH*" 
		"*DUMP-BYTES-DEFAULT-WIDTH*" 
		"*DUMP-DWORDS-DEFAULT-LENGTH*" 
		"*DUMP-DWORDS-DEFAULT-WIDTH*"
		"ENVIRONMENT-VARIABLE"
		"CAPTURE-ENVIRONMENT"
		"FRAME-BINDINGS" 
	)
	(:nicknames "DB"))

(in-package "DB")

(defvar *debug-prompt* "")
(defvar *debug-frame-pointer* nil)
(defvar *debug-max-level* nil)
(defvar *debug-min-level* nil)
(defvar *debug-max-levels* 30) ;; maximum stack frames we will examine

(defun is-relative-path (path-string)
	(eq (car (pathname-directory (pathname path-string))) ':relative))

;; returns total number of cells in uvector
(ccl:defasm ccl:uvector-length (uvec)
	{
		push	ebp
		mov		ebp, esp
		mov		eax, [ebp + ARGS_OFFSET]
		mov		eax, [eax - uvector-tag]
		shr		eax, 4
		and		eax, #xfffffff0
		pop		ebp
		ret
	})

(ccl:defasm ccl:uvector-type-tag (uvec)
	{
		push	ebp
		mov		ebp, esp
		mov		eax, [ebp + ARGS_OFFSET]
		mov		eax, [eax - uvector-tag]
		and		eax, #xf8
		pop		ebp
		ret
	})

;;; Find out the code generated by TRACE
(defun %dummy (x) x)
(trace %dummy)
(defparameter *traced-function-code* (cl::function-compiled-code #'%dummy))
(untrace %dummy)

(defun find-source (func)
    ;; if there is a code generator defined, this will have priority so find 
    ;; that one first
    (if (and (symbolp func) (x86::code-generator-function func))
        (setf func (x86::code-generator-function func)))
	(if (symbolp func)
		(setq func (symbol-function func)))
    
    ;; handle traced functions
    (if (and (functionp func) (eql (cl::function-compiled-code func) *traced-function-code*))
        (setf func (car (uref (cl::function-environment func) 2))))
    
	(let* ((file (function-source-file func))
		   (line (function-source-line func)))
		(unless file 
			(format *terminal-io* "No source file information available.")
			(return-from find-source nil))
        (when (pathnamep file) (setq file (namestring file)))
   		(if (is-relative-path file)
			(setq file (concatenate 'string ccl:*cormanlisp-directory* "\\" file)))	  
		(ed file)
		(ide::set-selection file line 0 line 200)
		t))

(defun display-character (n)
	(cond ((< n 32)	#\.)
		  ((<= 128 n 156) #\.)
		  ((int-char n))))

(defun is-bad-byte-ptr (addr)
	(win:IsBadReadPtr (ct:int-to-foreign-ptr addr) 1))

(defun is-bad-dword-ptr (addr)
	(win:IsBadReadPtr (ct:int-to-foreign-ptr addr) 4))
					
(defun dump-n-bytes (addr num stream &optional (added 0))
	(let ((char-dump-indent (+ 12 (* num 3))))
		(incf char-dump-indent (* added 3))
		(format stream "~X: " addr)
		(dotimes (i num)
			(if (is-bad-byte-ptr (+ addr i))
				(format stream "?? ")
				(format stream "~2,'0x " (peek-byte (+ addr i)))))
		(format stream "~vT|" char-dump-indent)
		(dotimes (i num)
			(if (is-bad-byte-ptr (+ addr i))
				(format stream "?")
				(format stream "~A" (display-character (peek-byte (+ addr i))))))
		(dotimes (i added)(write #\Space :stream stream :escape nil))
		(format stream "|~%" added)))

(defun dump-n-dwords (addr num stream)
	(format stream "~X: " addr)
	(dotimes (i num)
		(if (is-bad-dword-ptr (+ addr (* i 4)))
			(format stream "???????? ")
			(format stream "~8,'0x " (peek-dword (+ addr (* i 4))))))
	(format stream "~%"))

(defasm uvector-address (obj)
	{
		push	ebp
		mov		ebp, esp
		cmp 	ecx, 1
		jz 		short :t1
		callp 	_wrong-number-of-args-error
	:t1
		mov		eax, [ebp + ARGS_OFFSET]
		mov		edx, eax
		and		edx, 7
		cmp		edx, uvector-tag
		je		short :t2
		push	"Not a uvector: ~A"
		push	eax
		mov		ecx, 2
		callf	error
	:t2	
		sub		eax, uvector-tag
		push	eax
		callp	cl::%create-unsigned-lisp-integer
		add		esp, 4
		mov		ecx, 1
		pop		ebp
		ret
	})

(defasm cons-address (obj)
	{
		push	ebp
		mov		ebp, esp
		cmp 	ecx, 1
		jz 		short :t1
		callp 	_wrong-number-of-args-error
	:t1
		mov		eax, [ebp + ARGS_OFFSET]
		mov		edx, eax
		and		edx, 7
		cmp		edx, cons-tag
		je		short :t2
		push	"Not a cons: ~A"
		push	eax
		mov		ecx, 2
		callf	error
	:t2	
		sub		eax, cons-tag
		push	eax
		callp	cl::%create-unsigned-lisp-integer
		add		esp, 4
		mov		ecx, 1
		pop		ebp
		ret
	})

;; if the object is a pointer, see if it is a valid pointer
(defun cl::invalid-object-p (object)
	(if (consp object)
		(let ((addr (cons-address object)))
			(is-bad-dword-ptr (- addr x86::cons-tag)))
		(if (cl::uvectorp object)
			(let ((addr (uvector-address object)))
				(is-bad-dword-ptr addr)))))

(defun cl::invalid-object-string (object)
	(format nil "Invalid object: #x~X" (ccl::lisp-object-bits object)))
	
(defconstant *dump-bytes-default-length* 64)
(defconstant *dump-bytes-default-width* 8)
(defun dump-bytes (obj 
		&key (length nil)			;; length in bytes
			(stream *standard-output*) 
			(width *dump-bytes-default-width*))
	(let (addr)
		(cond ((integerp obj)
			   (setf addr obj)
			   (unless length (setf length *dump-bytes-default-length*)))
			  ((ct:cpointerp obj)
			   (unless length
					(setf length
				 		(if (or (cl::foreign-heap-p obj)(ct::foreign-stack-p obj))
								(uref obj 2)
								*dump-bytes-default-length*)))
			   (setf addr (ct:foreign-ptr-to-int obj)))
			  ((uvectorp obj)
			   (unless length (setf length (* (ccl:uvector-length obj) 4)))
			   (setf addr (uvector-address obj)))
			  ((consp obj)
			   (unless length (setf length 8))
			   (setf addr (cons-address obj))))

		(let* ((rows (truncate length width))
		  	   (remainder (mod length width)))
			(dotimes (i rows)
				(dump-n-bytes addr width stream)
				(incf addr width))
			(if (> remainder 0)
				(dump-n-bytes addr remainder stream (- width remainder)))))) 

(defconstant *dump-dwords-default-length* 32)
(defconstant *dump-dwords-default-width* 1)
(defun dump-dwords (obj 
		&key (length nil)
			(stream *standard-output*) 
			(width *dump-dwords-default-width*))

	(let (addr)
		(cond ((integerp obj)
			   (setf addr obj)
			   (unless length (setf length *dump-dwords-default-length*)))
			  ((ct:cpointerp obj)
			   (unless length
					(setf length
				 		(if (cl::foreign-heap-p obj)
								(uref obj 2)
								*dump-dwords-default-length*)))
			   (setf addr (ct:foreign-ptr-to-int obj)))
			  ((uvectorp obj)
			   (unless length (setf length (* (ccl:uvector-length obj) 4)))
			   (setf addr (uvector-address obj)))
			  ((consp obj)
			   (unless length (setf length 8))
			   (setf addr (cons-address obj))))

		;; round length up to a multiple of 4
		(let* ((num-dwords (truncate (+ length 3) 4))
			   (rows (truncate num-dwords width))
		 	  (remainder (mod num-dwords width)))
			(dotimes (i rows)
				(dump-n-dwords addr width stream)
				(incf addr (* width 4)))
			(if (> remainder 0)
				(dump-n-dwords addr remainder stream))))) 

(defun dump-error-stack (&optional (stream *standard-output*))
	(dolist (x cl::*error-trace*)
		(format stream "~S~%" x)))

;;;
;;;	Corman Lisp DISASSEMBLE-BYTES function
;;;		
(defun disassemble-bytes (addr num-bytes &optional (stream *standard-output*))
	(format stream ";Disassembling from address #x~x:~%" addr)
	(do* ((offset 0)
		  instruction
		  (instruction-bytes -1)
		  (count 0 (+ count 1)))
		((>= offset num-bytes))
		(multiple-value-setq (instruction instruction-bytes)
			(cl::disassembly-statement addr offset))
		(format stream ";#x~x:~4t~A~%" offset instruction)
		(if (= instruction-bytes 0)
			(incf instruction-bytes))	;; if RET, returns 0 as a flag
		(incf offset instruction-bytes)))	

(defstruct environment-variable name value register offset indirect-flag)
(defun make-environment (env)
	(let ((ret nil))
		(dotimes (i (/ (length env) 5))
			(let ((s (make-environment-variable
							:name (svref env (+ (* i 5) 0))
							:value (svref env (+ (* i 5) 1))
							:register (svref env (+ (* i 5) 2))
							:offset (svref env (+ (* i 5) 3))
							:indirect-flag (svref env (+ (* i 5) 4)))))
				(push s ret)))
		(nreverse ret)))

;;;
;;;	Corman Lisp CAPTURE-ENVIRONMENT macro.
;;; Example usage:
;;;	(let ((ht (make-hash-table)))
;;;		(defun foo (x y)
;;;			(let ((h ht))
;;;				(CAPTURE-ENVIRONMENT))))
;;;
(defmacro capture-environment () `(make-environment (cl::get-current-environment)))

(defun foreign-jump-table-capacity () (peek-dword (+ (cl::sys-globals-address) 12)))
(defun foreign-jump-table-num-entries () (peek-dword (+ (cl::sys-globals-address) 8)))

(in-package :common-lisp)
;;;;
;;;;	Common Lisp ROOM function
;;;;
(defun room (&optional x)
	(declare (ignore x))
    (let (ephemeral-1-size
          ephemeral-1-used
          ephemeral-2-size
          ephemeral-2-used)

     	(cl::gc 3)				;; flush all ephemeral heaps
        
        (multiple-value-bind (percent total used)
            (cl::heap-used 0)
            (declare (ignore percent))
            (setq ephemeral-1-size total ephemeral-1-used used))
        (multiple-value-bind (percent total used)
            (cl::heap-used 1)
            (declare (ignore percent))
            (setq ephemeral-2-size total ephemeral-2-used used))
                
    	(format t "~30TUsed~45TAvailable~60TTotal~%")
    	(format t "~30T----~45T---------~60T-----~%")
    	(let ((control "~A:~30T~D~45T~D~60T~D~%"))
    		(format t control
    			"Lisp Heap bytes"
    			(heap-currently-used)
    			(- (heap-capacity) (heap-currently-used))
    			(heap-capacity))
    		(format t control
    			"Ephemeral Heap 1 bytes"
    			ephemeral-1-used
    			(- ephemeral-1-size ephemeral-1-used)
    			ephemeral-1-size)
    		(format t control
    			"Ephemeral Heap 2 bytes"
    			ephemeral-2-used
    			(- ephemeral-2-size ephemeral-2-used)
    			ephemeral-2-size)
      		(format t control
    			"Jump table entries"
    			(jump-table-used)
    			(- (jump-table-capacity) (jump-table-used))
    			(jump-table-capacity))
    		(format t control
    			"Global symbol table entries"
    			(symbol-table-used)
    			(- (symbol-table-capacity) (symbol-table-used))
    			(symbol-table-capacity))
    		(format t control
    			"Foreign jump table entries"
    			(db::foreign-jump-table-num-entries)
    			(- (db::foreign-jump-table-capacity) (db::foreign-jump-table-num-entries))
    			(db::foreign-jump-table-capacity))))
	(values))

(in-package :db)

(defasm %get-frame-address (n start result)	;; get the nth frame address starting at passed pointer
	{
		push	ebp
		mov		ebp, esp
		mov		ecx, [ebp + (+ 8 ARGS_OFFSET)]	;; n
		mov		edx, [ebp + (+ 4 ARGS_OFFSET)]	;; start
		mov		eax, [ebp + (+ 0 ARGS_OFFSET)]	;; result
		shr		ecx, 3
		mov		edx, [edx + (uvector-offset cl::foreign-heap-ptr-offset)] ;; edx = base pointer
	:loop
		cmp		ecx, 0
		jz		:exit
		mov		edx, [edx]
		dec		ecx
		jmp		short :loop
	:exit
		mov		[eax + (uvector-offset cl::foreign-heap-ptr-offset)], edx
		mov		ecx, 1
		pop		ebp
		ret
	})

(defun get-frame-address (n) (%get-frame-address n *debug-frame-pointer* (ct:create-foreign-ptr)))

(defun get-frame-function (n)
	(let* ((addr (get-frame-address (- n 1)))
		   (retaddr (ct:cref (:unsigned-long *) addr 1)))
		(let ((func (cl::address-find-function retaddr)))
			(if (functionp func) func nil))))

(defvar *debug-level* 0)
(defvar *current-frame* nil)

(defun next-debug-level ()
	(do* ((func nil)
		  (level (+ *debug-level* 1) (+ level 1)))
		((or func (>= level *debug-max-level*))
		 (if func (- level 1)))
		(setf func (get-frame-function level))))

(defun prev-debug-level ()
	(do* ((func nil)
		  (level (- *debug-level* 1) (- level 1)))
		((or func (< level *debug-min-level*))
		 (if func (+ level 1)))
		(setf func (get-frame-function level))))

(defun function-debug-info (func)
	(let ((ccode (cl::function-compiled-code func)))
		(if ccode
			(let ((info (getf (uref ccode cl::compiled-code-info-offset) 'cl::stack-frame)))
				(if info (return-from function-debug-info info))))
		nil))

(defun frame-var-offset (x) 
	(setf x (logand x #xffffff))
	(if (/= (logand x #x800000) 0)
		(decf x #x1000000))
	x)

(defun frame-var-base (x) (logand (ash x -24) 3))
(defun frame-var-indirect (x) (logand (ash x -27) 1))

(defun frame-uses-ebx (info)
	(do ((i 5 (+ i 2)))
		((>= i (length info)) nil)
		(if (= (frame-var-base (svref info i)) 1)
			(return t))))

(defun offset-foreign-ptr (p offset) 
	(ct:int-to-foreign-ptr (+ (ct:cpointer-value p) offset)))

(defvar *save-compiled-func* nil)

(defun function-name (func) 
	(if (functionp func)
		(or (nth-value 2 (function-lambda-expression func)) func)))

(defasm get-env-cell (fp)
	{
		push	ebp
		mov		ebp, esp
		mov		eax, [ebp + ARGS_OFFSET]	;; eax = foreign pointer obj
		mov		eax, [eax + (uvector-offset cl::foreign-heap-ptr-offset)] ;; eax = foreign ptr
		mov		eax, [eax - 4]				;; eax = env
		mov		ecx, 1
		pop		ebp
		ret
	})
	
(defun prepare-frame-debug-info (func addr)
	(if func
		(let* ((info (function-debug-info func)))
			(unless info (return-from prepare-frame-debug-info nil))
			(let* ((heap-env (get-env-cell addr)) ;;need to convert from integer to struct
				   (arg-num (ct:cref (:unsigned-long *) addr -2)))
				(setf (svref info 0) addr)
				(setf (svref info 1)
					(if (frame-uses-ebx info) 
						(offset-foreign-ptr addr (+ (* arg-num 4) 4)) 
						0))
				(setf (svref info 2) heap-env)
				(setf (svref info 3) 0))
			info)))

(defun get-current-frame-info ()
	(prepare-frame-debug-info 
		(get-frame-function *debug-level*)
		(get-frame-address *debug-level*)))

(defun debug-format-cons (obj bits)
	(let ((pointer (logand bits -8)))
		(if (is-bad-dword-ptr pointer)
			(format nil "Invalid object: #x~X" bits)
			(format nil "~S" obj))))

(defun debug-filter-cons (obj bits)
	(let ((pointer (logand bits -8)))
		(if (is-bad-dword-ptr pointer)
			(format nil "Invalid object: #x~X" bits)
			obj)))

(defconstant uvector-length-tag 6)
(defun debug-format-uvector (obj bits)
	(let ((pointer (logand bits -8)))
		(if (is-bad-dword-ptr pointer)
			(format nil "Invalid object: #x~X" bits)
			(let* ((uvector-header (peek-dword pointer))
				   (tag-bits (logand uvector-header 7)))
				(if (/= tag-bits uvector-length-tag)
					(format nil "Invalid object: #x~X" bits)
					(format nil "~S" obj))))))

(defun debug-filter-uvector (obj bits)
	(let ((pointer (logand bits -8)))
		(if (is-bad-dword-ptr pointer)
			(format nil "Invalid object: #x~X" bits)
			(let* ((uvector-header (peek-dword pointer))
				   (tag-bits (logand uvector-header 7)))
				(if (/= tag-bits uvector-length-tag)
					(format nil "Invalid object: #x~X" bits)
					obj)))))

;; Formats the object as a string, watching for illegal bit patterns.
(defun debug-format (obj)
	(let* ((bits (ccl:lisp-object-bits obj))
		   (tag-bits (logand bits 7)))
		(handler-bind
			((win:memory-access-violation-error
				(lambda (condition)
					(declare (ignore condition))
					(return-from debug-format (format nil "Invalid object: #x~X" bits)))))	
			(cond ((= tag-bits 0) (format nil "~S" obj))	;; format fixnum
				  ((= tag-bits 1)
				   (if (= (logand bits 255) 1)
					   (format nil "~S" obj)				;; format character
					   (format nil "Invalid object: #x~X" bits)))
				  ((= tag-bits 4)(debug-format-cons obj bits))		;; format cons
				  ((= tag-bits 5)(debug-format-uvector obj bits))	;; format uvector
				  ((or (= tag-bits 3)(= tag-bits 7))
				   (format nil "~S" obj))					;; format short-float
				  (t (format nil "Invalid object: #x~X" bits))))))		

;; Returns the object, watching for illegal bit patterns.
;; An illegal object is converted to a string, using debug-format,
;; and the string is returned.
(defun debug-filter (obj)
	(let* ((bits (ccl:lisp-object-bits obj))
		   (tag-bits (logand bits 7)))
		(handler-bind
			((win:memory-access-violation-error
				(lambda (condition)
					(declare (ignore condition))
					(return-from debug-filter (format nil "Invalid object: #x~X" bits)))))	
			(cond ((= tag-bits 0) obj)
				  ((= tag-bits 1)
				   (if (= (logand bits 255) 1)
					   obj
					   (format nil "Invalid object: #x~X" bits)))
				  ((= tag-bits 4)(debug-filter-cons obj bits))
				  ((= tag-bits 5)(debug-filter-uvector obj bits))
				  ((or (= tag-bits 3)(= tag-bits 7)) obj)
				  (t (format nil "Invalid object: #x~X" bits))))))		
								
(defun display-frame (func addr)
	(unless (functionp func)
		(format *debug-io* ";;; No debugging information is available for this function.~%")
		(return-from display-frame))
	(let* ((info (prepare-frame-debug-info func addr))
		   (name (function-name func))
		   (file (function-source-file func))
		   (line (function-source-line func)))
		(unless info
			(format *debug-io* ";;; Call to function ~S:" name)
			(if file (format *debug-io* "~40T(File ~A, line ~A)" file line))
			(format *debug-io* "~%;;; No debugging information is available for this function.~%")
			(return-from display-frame))
		(let ((var-list nil))
			(do* ((i 4 (+ i 2))
				  sym)
				((>= i (length info)))
				(setf sym (svref info i))
				(push `(quote ,sym) var-list)
				(push `(debug-format ,sym) var-list))
			(let ((cl::*compiler-environment* info))
				(format *debug-io* ";;; Call to function ~S:" name)
				(if file (format *debug-io* "~40T(File ~A, line ~A)" file line))
				(eval `(format *debug-io* "~%~{;;; ~4T~S:~30T~A~%~}" (list ,@(nreverse var-list))))))))

(defun capture-frame (func addr)
	(let* ((info (prepare-frame-debug-info func addr)))
		(let ((var-list nil))
			(do* ((i 4 (+ i 2))
				  sym)
				((>= i (length info)))
				(setf sym (svref info i))
				(push `(quote ,sym) var-list)
				(push `(debug-filter ,sym) var-list))
			(let ((cl::*compiler-environment* info))
				(eval `(list ,@(nreverse var-list)))))))

(defun debug-max-level ()
	(do* ((i 2 (+ i 1))
		  (func (get-frame-function i)(get-frame-function i)))
		 (nil)
		(if (or (= i *debug-max-levels*) 
				(and func 
					(or (eq func cl::*top-level*)
						(eq (execution-address func) (execution-address cl::*top-level*)))))
			(return i))))

(defun debug-min-level () 2)
	
(defun get-backtrace ()
	(do* ((i *debug-level* (+ i 1))
		  (func (get-frame-function i)(get-frame-function i))
		  (funcs nil))
		 ((> i *debug-max-level*))
		(push func funcs)
		(if (or (= i *debug-max-levels*) (eq func cl::*top-level*))
			(return (nreverse funcs)))))

(defun print-backtrace ()
	(let ((bt (get-backtrace)))
		(dolist (func bt)
			(if (functionp func)				
				(let ((name (function-name func))
					  (file (function-source-file func))
					  (line (function-source-line func)))
					(format *debug-io* ";;; ~S" name)
					(if file (format *debug-io* "~40T(File ~A, line ~A)" file line))
					(format *debug-io* "~%"))
				#|(format *debug-io* ";;; No function information~%")|#))))
	
(defun set-current-frame-env ()
	(setf *current-frame* 
		(capture-frame 
			(get-frame-function *debug-level*) 
			(get-frame-address *debug-level*))))

(defun show-frame ()
	(let ((func  (get-frame-function *debug-level*))
		  (addr (get-frame-address *debug-level*)))
		(set-current-frame-env)
		(display-frame func addr)))

(defun next-frame ()
	(let ((next-level (next-debug-level)))
		(if next-level
			(progn 
				(setf *debug-level* next-level)
				(set-current-frame-env)
				(show-frame))
			(format *debug-io* ";;; Bottom of stack.~%"))))

(defun previous-frame ()
	(let ((prev-level (prev-debug-level)))
		(if prev-level
			(progn
				(setf *debug-level* prev-level)
				(set-current-frame-env)
				(show-frame))
			(format *debug-io* ";;; Top of stack.~%"))))

(defun go-frame ()
	(setf *debug-level* *debug-min-level*)
	(let* ((target (read *debug-io*))
           (bt (get-backtrace))
           f)
		(when (symbolp target)
			(setf f (position target bt :key 'function-name))
			(when f
				(setf *debug-level* (+ f 2))
				(set-current-frame-env)
				(show-frame)
				(return-from go-frame)))
		(format *debug-io* ";;; Unable to find frame of function named ~S~%" target)))

(defun top-frame ()
	(setf *debug-level* *debug-min-level*)
	(set-current-frame-env)
	(show-frame))

(defun bottom-frame ()
	(setf *debug-level* *debug-max-level*)
	(set-current-frame-env)
	(show-frame))			

(defun show-lambda () 
	(pprint 
		(function-lambda-expression 
			(get-frame-function *debug-level*)) 
		*debug-io*)
	(terpri *debug-io*))
	
(defun debugger-message ()
	(when (typep cl::*debug-condition* 'error)
		(format *debug-io* 
				";;; An error of type ~A was detected in function ~A:~%;;; Error: ~A~%" 
            (class-name (class-of cl::*debug-condition*))
		    cl::*error-function* 
            cl::*debug-condition*))
	(format *debug-io* 
		";;; Entering Corman Lisp debug loop. ~%;;; Use :C followed by an option to exit. Type :HELP for help.~%"))

(defun show-restart-options ()
	(when (> (length cl::*restart-registry*) 0)
		(format *debug-io* ";;; Restart options:~%")
		(let ((index 0))
			(dolist (restart cl::*restart-registry*)
				(let ((report-fn (cl::restart-report-function restart)))
					(when (functionp report-fn)
						(format *debug-io* ";;; ~D   " (+ index 1))
						(funcall report-fn *debug-io*)
						(terpri *debug-io*)
						(incf index)))))))
						
(defun debugger-continue ()
	(when (= (length cl::*restart-registry*) 0)
		(format *debug-io* "No restarts available.~%")
		(return-from debugger-continue))
	(let ((option (read *debug-io*)))
		(do ()
			((and (fixnump option)(> option 0)(<= option (length cl::*restart-registry*))))
			(format *debug-io* "Enter an integer restart option from 1 to ~A~%" 
				(length cl::*restart-registry*))
			(setf option (read *debug-io*))) 
		(let* ((restart (elt cl::*restart-registry* (- option 1)))
				   (interactive (cl::restart-interactive-function restart))
				   (args (if interactive (multiple-value-list (funcall interactive)))))
				(apply (cl::restart-function restart) args))))
										
(defun debugger-help ()
	(format *debug-io* "~%;;; Corman Lisp Debug Loop commands:~%")
	(format *debug-io* ";;; :C   (or :CONTINUE) integer       Exits the debug loop and invokes the specified restart option~%")
	(format *debug-io* ";;; :?   (or :HELP)                   Displays command list~%")
	(format *debug-io* ";;; :R   (or :RESTARTS)               Displays restart options~%")
	(format *debug-io* ";;; :F   (or :FRAME)                  Print the current stack frame~%")
	(format *debug-io* ";;; :B   (or :BACKTRACE)              Print a backtrace down from the current frame~%")
	(format *debug-io* ";;; :N   (or :NEXT)                   Go down the stack one frame~%")
	(format *debug-io* ";;; :P   (or :PREVIOUS)               Go up the stack one frame~%")
	(format *debug-io* ";;; :<   (or :TOP)                    Go to the top of the stack~%")
	(format *debug-io* ";;; :>   (or :BOTTOM)                 Go up the bottom of the stack~%")
	(format *debug-io* ";;; :G   (or :GO) function            Go up the specified frame~%")
	(format *debug-io* ";;; :L   (or :LAMBDA)                 Display the lambda expression for the current function~%"))
		
;;;
;;; Returns t if the passed expression was a debugger command and was handled.
;;;	Returns nil if not, and the debugger will then process the expression
;;; in the normal way.
;;;
(defun process-debug-command (expr)
	(cond ((member expr '(:f :frame))			(show-frame))
		  ((member expr '(:c :cont :continue))	(debugger-continue))
		  ((member expr '(:r :restarts)) 		(show-restart-options))
		  ((member expr '(:help :?))			(debugger-help))
		  ((member expr '(:b :backtrace))		(print-backtrace))	
		  ((member expr '(:n :next))			(next-frame))	
		  ((member expr '(:p :previous))		(previous-frame))	
		  ((member expr '(:< :top))				(top-frame))	
		  ((member expr '(:> :bottom))			(bottom-frame))	
		  ((member expr '(:g :go))				(go-frame))	
		  ((member expr '(:l :lambda))			(show-lambda))	
		  (t 									(return-from process-debug-command nil)))
	t)

(defasm stash-ebp (pointer)
	{
		push	ebp
		mov		ebp, esp
		mov		eax, [ebp + ARGS_OFFSET]
		mov		edx, ebp
		mov		edx, [edx]
		mov		[eax + (uvector-offset cl::foreign-heap-ptr-offset)], edx
		mov		ecx, 1
		pop		ebp
		ret
	})

(defun frame-bindings () 
	"Returns the variable bindings in the current debug frame."
	*current-frame*)
	
(defun cl::debugger ()
	;; throw away any pending input in *debug-io*
	(clear-input *debug-io*)
	(let* ((*debug-level* (debug-min-level))
		   (*debug-frame-pointer* (stash-ebp (ct:create-foreign-ptr)))
		   (*debug-max-level* (debug-max-level))
		   (*debug-min-level* (debug-min-level))
		   (*current-frame*	(set-current-frame-env))
           (*read-suppress* nil))       ;; in case this was true 	
		(debugger-message)
		(show-restart-options)
		(force-output *debug-io*)
		(do (expr 
			 result 
			 (normal-exit nil) 
			 sys-exception
			 (cl::*read-level* 0 0))
			(nil)
			(catch 'common-lisp::%error
				(setq sys-exception
					(catch :system-exception
						(progn
							(setq normal-exit nil)
							(write *debug-prompt* :stream *debug-io* :escape nil) 
							(setq expr (read *debug-io* nil 'Eof nil))
							(setq - expr)
							(unless (process-debug-command expr)
								(setq result 
									(multiple-value-list
										(let ((cl::*compiler-environment* (get-current-frame-info))) 
											(eval expr))))
								(cl::update-toplevel-globals expr result)
								(if (null result) 
									(force-output *debug-io*)
									(dolist (i result)
										(write i :stream *debug-io*)
										(terpri *debug-io*)
										(force-output *debug-io*))))
							(setq normal-exit t))))
				(unless normal-exit
					(progn
						(format *debug-io* "A system exception was caught: ~A~%" sys-exception)
						(force-output *debug-io*)
						(if (eq sys-exception :exception-stack-overflow)
							(cl::protect-stack))))))))
								
(defun get-frame-function-name (n)
	(let ((func (get-frame-function n)))
		(if (functionp func)
			(function-name func)
			func)))

(defun display-function-call-stack (max-depth)
	(dotimes (i max-depth (values))
		(let ((func (db::get-frame-function (+ i 1))))
			(format t "~A~%"
				(if (functionp func)
					(let ((func-name
						   (nth-value 2
								(function-lambda-expression func))))
						(or func-name func))
					func))
			(if (eq func ccl:*top-level*)
				(return (values))))))


;;; functions for dumping foreign structs and stuff
(in-package :c-types)
(defvar *foreign-print-length* 100)
(defun print-foreign-element (ptr type)
	(if (symbolp type)
		(ecase type
			(:short (format t "~W" (ct:cref (:short *) ptr 0)))
			(:long (format t "~W" (ct:cref (:long *) ptr 0)))
			(:char (format t "~W" (ct:cref (:char *) ptr 0)))
			(:unsigned-short (format t "~W" (ct:cref (:unsigned-short *) ptr 0)))
			(:unsigned-long (format t "~W" (ct:cref (:unsigned-long *) ptr 0)))
			(:unsigned-char (format t "~W" (ct:cref (:unsigned-char *) ptr 0)))
			(:single-float (format t "~W" (ct:cref (:single-float *) ptr 0)))
			(:double-float (format t "~W" (ct:cref (:double-float *) ptr 0)))
			(:handle (format t "~W" (ct:cref (:handle *) ptr 0))))))

(defun print-foreign-struct (ptr type)
	(let* ((start (ct:foreign-ptr-to-int ptr)))
		(format t "(" ;)
			)
		(do* ((x (cdr type) (cddr x))
			  (subtype (cadr x)(cadr x))
			  (offset 0))
			((endp x))
			(print-foreign-subform (ct:int-to-foreign-ptr (+ start offset)) (list subtype '*))
			(format t " ")
			(incf offset (ct:sizeof subtype)))
		(format t ")" ; (
			)))

(defun print-foreign-array (ptr type)
	(format t "(")  ;)
	(let* ((start (ct:foreign-ptr-to-int ptr))
		   (subtype (car type))
		   (range (cadr type))
		   (size (ct:sizeof subtype)))
		(dotimes (i (min range *foreign-print-length*))
			(print-foreign-subform (ct:int-to-foreign-ptr (+ start (* i size)))
				(list subtype '*))
			(format t " ")))
	(format t ")" ;(
		))

(defun print-foreign-ptr (ptr type)
	(print-foreign-element ptr (car type)))

(defun print-foreign-subform (ptr type)
	(cond ((symbolp type)(print-foreign-element ptr type))
		  ((eq (car type) ':struct)(print-foreign-struct ptr type))
		  ((eq (cadr type) '*)(print-foreign-subform ptr (car type)))
		  ((integerp (cadr type))(print-foreign-array ptr type))
		  (t (error "Invalid foreign type: ~S" type))))
	
(defun print-foreign (ptr type)
	(unless (valid-c-type-definition type)
		(error "Unknown foreign type: ~S" type))
	(setq type (ctypeexpand-all type))
	(unless (cl::foreign-ptr-p ptr)
		(error "Not a foreign pointer: ~S" ptr))
	(if (symbolp type)
		(error "Foreign type must be a pointer, array or structure type: ~S" type))
	(format t "#%~S[" type)
	(print-foreign-subform ptr type)
	(format t "]"))