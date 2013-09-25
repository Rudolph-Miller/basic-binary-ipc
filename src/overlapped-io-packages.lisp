(defpackage "BASIC-BINARY-IPC.OVERLAPPED-IO"
  (:use "COMMON-LISP")
  (:import-from "BASIC-BINARY-IPC"
		#:define-check-system-call
		#:define-system-call)
  ;; Requests
  (:export #:request
	   #:free-request
	   #:invalidp
	   #:waitingp
	   #:completedp

	   #:with-request
	   #:do-with-request)

  ;; Synchronising
  (:export #:wait-for-request
	   #:wait-for-requests)

  ;; Monitor Synchronising
  (:export #:monitor
	   #:unmonitor
	   #:pop-notification
	   #:free-monitor
	   #:do-with-monitor
	   #:with-monitor)

  ;; Generic handle stuff
  (:export #:close-handle
	   #:with-handle
	   #:do-with-handle
	   #:cancel-all-io)

  ;; Named Pipes
  (:export #:connect-to-named-pipe

	   ;; Servers
	   #:make-named-pipe-server
	   #:connect-named-pipe

	   #:buffer
	   #:buffer-length

	   #:read-file
	   #:read-file-request
	   #:bytes-read

	   #:write-file
	   #:write-file-request
	   #:bytes-written))
