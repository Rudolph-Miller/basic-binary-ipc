(in-package "BASIC-BINARY-IPC")

;;;; POSIX-ERROR condition (TEMPORARY)
(define-condition posix-error (error)
  ())

(define-condition posix-error/system-function-error (posix-error)
  ((system-function-error
    :initarg :system-function-error
    :reader system-function-error))
  (:report (lambda (condition stream)
	     (format stream "~A" (system-function-error condition)))))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun do-wrap-system-function-error-progn (function)
    (handler-case (funcall function)
      (system-function-error (c)
	(error 'posix-error/system-function-error :system-function-error c))))

  (defmacro wrap-system-function-error-progn (&body body)
    `(do-wrap-system-function-error-progn #'(lambda () ,@body))))

;;;; File handle stream
(defvar *default-read-buffer-size* 4098
  "The number of unsigned bytes to use to store data read from a socket.")

(defclass file-handle-stream (stream-socket)
  ((descriptor
    :initarg :descriptor
    :accessor descriptor)
   (read-request
    :initarg :read-request
    :reader read-request)
   (write-request
    :initarg :write-request
    :reader write-request)
   (read-buffer-size
    :initarg :read-buffer-size
    :reader read-buffer-size)
   (read-buffer
    :initarg :read-buffer
    :reader read-buffer)
   (interface-buffer
    :initarg :interface-buffer
    :reader interface-buffer))
  (:default-initargs
   :read-buffer-size *default-read-buffer-size*
   :read-buffer (cffi:foreign-alloc :uint8 :count *default-read-buffer-size*)
   :interface-buffer (make-array *default-read-buffer-size* :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)
   :read-request (make-instance 'basic-binary-ipc.overlapped-io:read-file-request)
   :write-request (make-instance 'basic-binary-ipc.overlapped-io:write-file-request)))

(defmethod initialize-instance :after ((object file-handle-stream) &key)
  (with-accessors ((descriptor descriptor)
		   (read-buffer read-buffer)
		   (read-buffer-size read-buffer-size)
		   (read-request read-request)
		   (write-request write-request))
      object
    (setf (basic-binary-ipc.overlapped-io:descriptor read-request) descriptor
	  (basic-binary-ipc.overlapped-io:descriptor write-request) descriptor)

    (basic-binary-ipc.overlapped-io:read-file descriptor
					      read-buffer 
					      read-buffer-size
					      read-request)))

(defmethod close-socket ((socket file-handle-stream))
  (with-slots (read-buffer descriptor) socket
    (unless (cffi:null-pointer-p read-buffer)
      (basic-binary-ipc.overlapped-io:close-handle (descriptor socket))
      (setf descriptor 0)

      (cffi:foreign-free read-buffer)
      (setf read-buffer (cffi:null-pointer)))))

(defmethod ready-to-write-p ((socket file-handle-stream))
  (and (connection-succeeded-p socket)
       (basic-binary-ipc.overlapped-io:completedp (write-request socket))
       (basic-binary-ipc.overlapped-io:succeededp (write-request socket))))

(defmethod data-available-p ((socket file-handle-stream))
  (or (plusp (length (interface-buffer socket)))
      (and (basic-binary-ipc.overlapped-io:completedp (read-request socket))
	   (basic-binary-ipc.overlapped-io:succeededp (read-request socket)))))

(defmethod write-to-stream ((socket file-handle-stream) buffer &key start end)
  (check-type buffer (simple-array (unsigned-byte 8) (*)))
  (check-type start (or null (integer 0)))
  (check-type end (or null (integer 0)))
  (cond
    ((ready-to-write-p socket)
     (let* ((start (or start 0))
	    (end (or end (length buffer)))
	    (length (- end start)))
       (check-type length (integer 0))

       (when (or (minusp start) (> start (length buffer)))
	 (error "START argument is invalid. ~d" start))

       (when (> end (length buffer))
	 (error "END argument is invalid. ~d" end))

       (with-accessors ((descriptor descriptor)
			(write-request write-request))
	   socket
	 (cffi:with-pointer-to-vector-data (buffer-ptr buffer)
	   (let ((start-ptr (cffi:inc-pointer buffer-ptr start)))
	     (basic-binary-ipc.overlapped-io:write-file descriptor start-ptr length write-request)
	     length)))))
    (t
     0)))

(defun transfer-read-buffer-data (socket)
  "Copy the data from READ-BUFFER to the INTERFACE-BUFFER."
  (check-type socket file-handle-stream)  
  (with-accessors ((read-buffer read-buffer)
		   (read-buffer-size read-buffer-size)
		   (read-request read-request)
		   (interface-buffer interface-buffer))
      socket
    (assert (basic-binary-ipc.overlapped-io:succeededp read-request))
    (let ((bytes-read (basic-binary-ipc.overlapped-io:bytes-read read-request)))      
      (adjust-array interface-buffer (+ (length interface-buffer) bytes-read))
      (dotimes (index bytes-read)
	(vector-push (cffi:mem-aref read-buffer :uint8 index) interface-buffer))
      bytes-read)))

(defmethod read-from-stream ((socket file-handle-stream) buffer &key start end peek)  
  (check-type buffer (simple-array (unsigned-byte 8) (*)))
  (check-type start (or null (integer 0)))
  (check-type end (or null (integer 0)))
  (with-accessors ((interface-buffer interface-buffer)
		   (read-buffer read-buffer)
		   (read-buffer-size read-buffer-size)
		   (read-request read-request)
		   (descriptor descriptor))
      socket
    (let* ((start (or start 0))
	   (end (or end (length buffer)))
	   (maximum-bytes-to-read (- end start)))
      (check-type maximum-bytes-to-read (integer 0))

      (when (or (minusp start) (> start (length buffer)))
	(error "START argument is invalid: ~d" start))

      (when (> end (length buffer))
	(error "END ARGUMENT is invalid: ~d" end))

      ;; Fill the interface buffer
      (loop
	 :while (and (> maximum-bytes-to-read (length interface-buffer))
		     (basic-binary-ipc.overlapped-io:completedp read-request)
		     (basic-binary-ipc.overlapped-io:succeededp read-request))
	 :do
	 (transfer-read-buffer-data socket)
	 (basic-binary-ipc.overlapped-io:read-file descriptor
						   read-buffer
						   read-buffer-size
						   read-request))
      (let* ((bytes-read (min maximum-bytes-to-read (length interface-buffer)))
	     (bytes-left (- (length interface-buffer) bytes-read)))
	(check-type bytes-read (integer 0))
	(check-type bytes-left (integer 0))
	;; Copy the data over to the buffer
	(loop
	   :for index :from 0 :below bytes-read
	   :for position :from start
	   :do
	   (setf (aref buffer position) (aref interface-buffer index)))
	;; Reorganise the interface buffer.
	(unless peek
	  (loop
	     :for position :from 0 :below bytes-left
	     :for index :from bytes-read
	     :do
	     (setf (aref interface-buffer position) (aref interface-buffer index)))
	  (setf (fill-pointer interface-buffer) bytes-left))
	bytes-read))))

;;;; Local namespace
(defclass local-server (stream-server)
  ((local-pathname
    :initarg :local-pathname
    :reader local-pathname)
   (descriptor
    :initarg :descriptor
    :accessor descriptor)
   (connect-request
    :initarg :connect-request
    :reader connect-request)))

(defmethod close-socket ((socket local-server))  
  (basic-binary-ipc.overlapped-io:close-handle (descriptor socket))
  (basic-binary-ipc.overlapped-io:free-request (connect-request socket)))

(defclass local-stream (file-handle-stream)
  ((determinedp-request
    :initarg :determinedp-request
    :reader determinedp-request)
   (local-pathname
    :initarg :local-pathname
    :reader local-pathname))
  (:default-initargs
   :determinedp-request (let ((rv (make-instance 'basic-binary-ipc.overlapped-io:request)))
			  (basic-binary-ipc.overlapped-io:set-event rv)
			  rv)))

(defmethod close-socket ((socket local-stream))
  (call-next-method)
  (basic-binary-ipc.overlapped-io:free-request (determinedp-request socket)))

(defmethod determinedp ((socket local-stream))
  t)

(defmethod connection-succeeded-p ((socket local-stream))
  (let ((request (read-request socket)))
    (not (and (basic-binary-ipc.overlapped-io:completedp request)
	      (basic-binary-ipc.overlapped-io:failedp request)))))

(defmethod connection-failed-p ((socket local-stream))
  (not (connection-succeeded-p socket)))

(defmethod remote-disconnected-p ((socket local-stream))
  (not (connection-succeeded-p socket)))

(defun make-local-server (pathname &key &allow-other-keys)
  (let ((handle (wrap-system-function-error-progn
		  (basic-binary-ipc.overlapped-io:make-named-pipe-server pathname
									 :first-instance t))))
    (alexandria:unwind-protect-case ()
      (make-instance 'local-server
		     :local-pathname pathname
		     :descriptor handle
		     :connect-request (basic-binary-ipc.overlapped-io:connect-named-pipe handle))
      (:abort
       (basic-binary-ipc.overlapped-io:close-handle handle)))))

(defmethod connection-available-p ((server local-server))
  (basic-binary-ipc.overlapped-io:completedp (connect-request server)))

(defmethod accept-connection ((server local-server))
  (cond
    ((basic-binary-ipc.overlapped-io:completedp (connect-request server))
     (assert (basic-binary-ipc.overlapped-io:succeededp (connect-request server)))
     (prog1 (make-instance 'local-stream
			   :descriptor (descriptor server)
			   :local-pathname (local-pathname server))
       (let ((handle (basic-binary-ipc.overlapped-io:make-named-pipe-server (local-pathname server))))
	 (alexandria:unwind-protect-case ()	    
	     (progn
	       (basic-binary-ipc.overlapped-io:connect-named-pipe handle (connect-request server))
	       (setf (descriptor server) handle))
	   (:abort
	    (basic-binary-ipc.overlapped-io:close-handle handle))))))
    (t
     (error 'no-connection-available-error :socket server))))

(define-condition no-local-server-error (error)
  ((local-pathname
    :initarg :local-pathname
    :reader local-pathname))
  (:report (lambda (condition stream)
	     (format stream "No named pipe server exists at pathname ~S." (local-pathname condition)))))

(defun connect-to-local-server (pathname &key &allow-other-keys)
  (handler-case (let ((handle (basic-binary-ipc.overlapped-io:connect-to-named-pipe pathname)))
		  (make-instance 'local-stream
				 :descriptor handle
				 :local-pathname pathname))
    (system-function-error (c)
      (if (eql :error-file-not-found (system-function-error-value c))
	  (error 'no-local-server-error :local-pathname pathname)
	  (error c)))))

;;;; IPv4 Namespace
(defparameter +ipv4-loopback+ basic-binary-ipc.overlapped-io:+inaddr-loopback+)
(defparameter +ipv4-any+ basic-binary-ipc.overlapped-io:+inaddr-any+)

(defclass ipv4-tcp-server (stream-server)
  ((descriptor
    :initarg :descriptor
    :reader descriptor)
   (client-descriptor
    :initarg :client-descriptor
    :accessor client-descriptor
    :documentation "The handle for the next client that is about to connect.")
   (accept-request
    :initarg :accept-request
    :reader accept-request)
   (host-address
    :initarg :host-address
    :reader host-address)
   (port
    :initarg :port
    :reader port)
   (accept-buffer
    :initarg :accept-buffer
    :reader accept-buffer)
   (accept-buffer-size
    :initarg :accept-buffer-size
    :reader accept-buffer-size))
  (:default-initargs
   :accept-request (make-instance 'basic-binary-ipc.overlapped-io:accept-ipv4-request)
   :accept-buffer (cffi:foreign-alloc :uint8 :count (basic-binary-ipc.overlapped-io:minimum-accept-ipv4-buffer-size))
   :accept-buffer-size (basic-binary-ipc.overlapped-io:minimum-accept-ipv4-buffer-size)))

(defmethod close-socket ((socket ipv4-tcp-server))
  (basic-binary-ipc.overlapped-io:close-socket (descriptor socket))
  (basic-binary-ipc.overlapped-io:close-socket (client-descriptor socket))
  (basic-binary-ipc.overlapped-io:free-request (accept-request socket))
  (cffi:foreign-free (accept-buffer socket)))

(defmethod connection-available-p ((server ipv4-tcp-server))
  (basic-binary-ipc.overlapped-io:completedp (accept-request server)))

(defun make-ipv4-tcp-server (host-address port &key (backlog 5) &allow-other-keys)
  (let* ((descriptor (handler-case (basic-binary-ipc.overlapped-io:make-ipv4-server host-address port :backlog backlog)
		       (system-function-error (c)
			 (error 'posix-error/system-function-error :system-function-error c))))
	 (client-descriptor (basic-binary-ipc.overlapped-io:make-socket :af-inet :sock-stream :ipproto-tcp))
	 (server (make-instance 'ipv4-tcp-server
				:descriptor descriptor
				:client-descriptor client-descriptor
				:host-address host-address
				:port port)))
    (alexandria:unwind-protect-case ()
	(basic-binary-ipc.overlapped-io:accept-ipv4 descriptor
						    client-descriptor
						    (accept-buffer server)
						    (accept-buffer-size server)
						    (accept-request server))
      (:abort
       (close-socket server)))
    server))

(defclass ipv4-tcp-stream (file-handle-stream)
  ((local-address
    :initarg :local-address
    :reader local-address)
   (local-port
    :initarg :local-port
    :reader local-port)
   (remote-address
    :initarg :remote-address
    :reader remote-address)
   (remote-port
    :initarg :remote-port
    :reader remote-port)))

(defmethod connection-succeeded-p ((socket ipv4-tcp-stream))
  (with-accessors ((read-request read-request)) socket
    (or (and (basic-binary-ipc.overlapped-io:completedp read-request)
	     (basic-binary-ipc.overlapped-io:succeededp read-request))
	t)))

(defmethod connection-failed-p ((socket ipv4-tcp-stream))
  (with-accessors ((read-request read-request)) socket
    (and (basic-binary-ipc.overlapped-io:completedp read-request)
	 (basic-binary-ipc.overlapped-io:failedp read-request))))


(defclass ipv4-tcp-stream/server (ipv4-tcp-stream)
  ((determinedp-request
    :initarg :determinedp-request
    :reader determinedp-request))
  (:default-initargs
   :determinedp-request (let ((rv (make-instance 'basic-binary-ipc.overlapped-io:request)))
			  (basic-binary-ipc.overlapped-io:set-event rv)
			  rv)))

(defmethod close-socket ((socket ipv4-tcp-stream/server))
  (call-next-method)
  (basic-binary-ipc.overlapped-io:free-request (determinedp-request socket)))

(defmethod determinedp ((socket ipv4-tcp-stream/server))
  t)

(defmethod accept-connection ((server ipv4-tcp-server))
  (cond
    ((connection-available-p server)
     (with-accessors ((descriptor descriptor)
		      (client-descriptor client-descriptor)
		      (accept-request accept-request)
		      (accept-buffer accept-buffer)
		      (accept-buffer-size accept-buffer-size))
	 server
       (let ((accepted-client-descriptor client-descriptor))
	 (prog1 (make-instance 'ipv4-tcp-stream/server
			       :descriptor accepted-client-descriptor
			       :local-address (basic-binary-ipc.overlapped-io:local-address accept-request)
			       :local-port (basic-binary-ipc.overlapped-io:local-port accept-request)
			       :remote-address (basic-binary-ipc.overlapped-io:remote-address accept-request)
			       :remote-port (basic-binary-ipc.overlapped-io:remote-port accept-request))
	   (let ((new-descriptor (basic-binary-ipc.overlapped-io:make-socket :af-inet :sock-stream :ipproto-tcp)))
	     (setf (client-descriptor server) new-descriptor)
	     (alexandria:unwind-protect-case ()
		 (progn
		   (basic-binary-ipc.overlapped-io:accept-ipv4 descriptor new-descriptor
							       accept-buffer accept-buffer-size
							       accept-request))
	       (:abort
		;; At this point the ACCEPT-REQUEST object is in a bad
		;; state. This means SERVER will no longer be able to
		;; accept new connections. I am not sure what it is
		;; that I should now, so I'll just close everything.
		(basic-binary-ipc.overlapped-io:close-socket accepted-client-descriptor)
		(close-socket server))))))))
    (t
     (error 'no-connection-available-error :socket server))))

(defclass ipv4-tcp-stream/client (ipv4-tcp-stream)
  ((connect-request
    :initarg :connect-request
    :reader connect-request)))

(defmethod close-socket ((socket ipv4-tcp-stream/client))
  (call-next-method)
  (basic-binary-ipc.overlapped-io:free-request (connect-request socket)))

(defmethod determinedp ((socket ipv4-tcp-stream/client))
  (basic-binary-ipc.overlapped-io:completedp (connect-request socket)))

(defun connect-to-ipv4-tcp-server (host-address port &key local-host-address local-port)
  (let ((local-host-address (or local-host-address +ipv4-loopback+))
	(local-port (or local-port 0)))
    (labels ((perform (descriptor request)
	       (basic-binary-ipc.overlapped-io:connect-ipv4 descriptor
							    host-address port
							    request
							    local-host-address local-port)
	       (make-instance 'ipv4-tcp-stream/client
			      :descriptor descriptor
			      :connect-request request
			      :local-address (basic-binary-ipc.overlapped-io:local-address request)
			      :local-port (basic-binary-ipc.overlapped-io:local-port request)
			      :remote-address (basic-binary-ipc.overlapped-io:remote-address request)
			      :remote-port (basic-binary-ipc.overlapped-io:remote-port request))))
      (let ((descriptor (basic-binary-ipc.overlapped-io:make-socket :af-inet :sock-stream :ipproto-tcp))
	    (request (make-instance 'basic-binary-ipc.overlapped-io:connect-ipv4-request)))
	(alexandria:unwind-protect-case ()
	    (perform descriptor request)
	  (:abort
	   (basic-binary-ipc.overlapped-io:close-socket descriptor)
	   (basic-binary-ipc.overlapped-io:free-request request)))))))

;;;; Polling
(defgeneric poll-socket-request (socket socket-event))
;; File handle streams
(defmethod poll-socket-request ((socket file-handle-stream) (socket-event (eql 'data-available-p)))
  (read-request socket))

(defmethod poll-socket-request ((socket file-handle-stream) (socket-event (eql 'ready-to-write-p)))
  (write-request socket))

(defmethod poll-socket-request ((socket file-handle-stream) (socket-event (eql 'remote-disconnected-p)))
  (read-request socket))

;; Local server
(defmethod poll-socket-request ((socket local-server) (socket-event (eql 'connection-available-p)))
  (connect-request socket))

;; Local streams
(defmethod poll-socket-request ((socket local-stream) (socket-event (eql 'determinedp)))
  (determinedp-request socket))

(defmethod poll-socket-request ((socket local-stream) (socket-event (eql 'connection-succeeded-p)))
  (determinedp-request socket))

(defmethod poll-socket-request ((socket local-stream) (socket-event (eql 'connection-failed-p)))
  (read-request socket))

;; IPv4 TCP Server
(defmethod poll-socket-request ((socket ipv4-tcp-server) (socket-event (eql 'connection-available-p)))
  (accept-request socket))

;; IPv4 TCP Stream (created using CONNECT-TO-IPV4-TCP-SERVER)
(defmethod poll-socket-request ((socket ipv4-tcp-stream/client) (socket-event (eql 'determinedp)))
  (connect-request socket))

(defmethod poll-socket-request ((socket ipv4-tcp-stream/client) (socket-event (eql 'connection-succeeded-p)))
  (connect-request socket))

(defmethod poll-socket-request ((socket ipv4-tcp-stream/client) (socket-event (eql 'connection-failed-p)))
  (connect-request socket))

;; IPv4 TCP Stream (created using ACCEPT-CONNECTION)
(defmethod poll-socket-request ((socket ipv4-tcp-stream/server) (socket-event (eql 'determinedp)))
  (determinedp-request socket))

(defmethod poll-socket-request ((socket ipv4-tcp-stream/server) (socket-event (eql 'connection-succeeded-p)))
  (determinedp-request socket))

(defmethod poll-socket-request ((socket ipv4-tcp-stream/server) (socket-event (eql 'connection-failed-p)))
  (read-request socket))

(defun poll-socket (socket socket-events timeout)
  (first (poll-sockets (list socket) (list socket-events) timeout)))

(defun poll-sockets (all-sockets all-socket-events timeout)
  (check-type all-sockets sequence)
  (check-type all-socket-events sequence)
  (check-type timeout (or (real 0) (member :indefinite :immediate)))
  (let* ((timeout (cond
		    ((eql timeout :indefinite)
		     basic-binary-ipc.overlapped-io::+infinite+)
		    ((eql timeout :immediate)
		     0)
		    (t
		     (coerce (round (/ timeout 1000)) 'integer))))
	 (all-socket-requests (mapcar #'(lambda (socket socket-events)
					  (mapcar #'(lambda (socket-event)
						      (poll-socket-request socket socket-event))
						  (if (listp socket-events)
						      socket-events
						      (list socket-events))))
				      all-sockets all-socket-events))
	 (all-requests (reduce #'append all-socket-requests))
	 (request (basic-binary-ipc.overlapped-io:wait-for-requests all-requests timeout)))
    (mapcar #'(lambda (socket socket-events socket-requests)
		(let ((matches (loop
				  :for socket-event :in (if (listp socket-events)
							    socket-events
							    (list socket-events))
				  :for socket-request :in socket-requests
				  :when (and (eql request socket-request)
					     (ecase socket-event
					       (connection-available-p
						(connection-available-p socket))
					       (remote-disconnected-p
						(remote-disconnected-p socket))
					       (ready-to-write-p
						(ready-to-write-p socket))
					       (data-available-p
						(data-available-p socket))
					       (determinedp
						(determinedp socket))
					       (connection-failed-p
						(connection-failed-p socket))
					       (connection-succeeded-p
						(connection-succeeded-p socket))))
				  :collect socket-event)))
		  (if (listp socket-events)
		      matches
		      (first matches))))
	    all-sockets all-socket-events all-socket-requests)))