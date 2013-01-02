(in-package "BASIC-BINARY-PACKET.NETWORK")

(defclass client ()
  ((socket
    :initarg :socket
    :reader socket)
   (event-base
    :initarg :event-base
    :reader event-base)
   (on-error
    :initarg :on-error
    :accessor on-error)
   (on-connection
    :initarg :on-connection
    :accessor on-connection)
   (on-object
    :initarg :on-object
    :accessor on-object)

   (state
    :accessor state)
   (read-buffer
    :reader read-buffer
    :initform (make-array '(1000) :element-type '(unsigned-byte 8)))
   (packet-accumulator
    :reader packet-accumulator
    :initform (basic-binary-packet:make-packet-reader-function)))
  (:default-initargs
   :event-base (default-event-base)
   :on-error nil
   :on-connection nil
   :on-object nil))

(defgeneric client/read (client state))
(defgeneric client/write (client state))

;; CONNECTING STATE
 
(defmethod client/read ((client client) (state (eql :connecting)))
  (handler-case (progn
		  (listen (socket client))
		  (error "Should not get here."))
    (socket-connection-refused-error (c)
      (client/error client c))))

(defmethod client/write ((client client) (state (eql :connecting)))
  (handler-case (progn
		  ;; It appears that client/write can be called in the
		  ;; event that the connection is refused too. To make
		  ;; sure we don't transition we check that the socket
		  ;; is operational by calling LISTEN. If LISTEN does
		  ;; not signal an error then we can transition to the
		  ;; next state.
		  (listen (socket client))
		  (setf (state client) :connected)
		  (call-callback (on-connection client) client))
    (socket-connection-refused-error (c)
      (client/error client c))))

;; CONNECTED STATE
(defmethod client/read ((client client) (state (eql :connected)))
  (multiple-value-bind (read-buffer bytes-read) (receive-from (socket client) :buffer (read-buffer client))
    (if (zerop bytes-read)
	(client/error client (make-instance 'end-of-file :stream (socket client)))
	(dotimes (i bytes-read)
	  (multiple-value-bind (payload identifier) (funcall (packet-accumulator client) (elt read-buffer i))
	    (when payload
	      (flexi-streams:with-input-from-sequence (in payload)
		(let ((obj (basic-binary-packet:decode-object in)))
		  (call-callback (on-object client) client obj identifier)))))))))

(defmethod client/write ((client client) (state (eql :connected)))
  (listen (socket client)))

;; All other states should generate an error.

(defmethod basic-binary-packet:write-object ((client client) object &key (identifier 0) binary-type)
  (basic-binary-packet:write-object (socket client) object
				    :identifier identifier
				    :binary-type binary-type))

(defun client/error (client exception)
  (close client)
  (call-callback (on-error client) client exception))

(defmethod initialize-instance :after ((self client) &key)
  (setf (state self) :connecting)
  (labels ((handler (fd event exception)
	     (declare (ignore fd))
	     (ecase event
	       (:read
		(print (list :read self (state self)))
		(client/read self (state self)))
	       (:write
		(print (list :write self (state self)))
		(client/write self (state self)))
	       (:error
		(client/error self exception)))))
    (set-io-handler (event-base self) (socket-os-fd self) :read  #'handler)
    (set-io-handler (event-base self) (socket-os-fd self) :write #'handler)
    (set-error-handler (event-base self) (socket-os-fd self) #'handler)))

(defmethod close ((stream client) &key abort)
  (unless (eql (state stream) :closed)
    (remove-fd-handlers (event-base stream) (socket-os-fd stream) :error t :read t :write t)
    (close (socket stream) :abort abort)
    (setf (state stream) :closed))
  nil)

(defmethod socket-os-fd ((object client))
  (let ((rv (socket-os-fd (socket object))))
    (assert rv)
    rv))

(defun make-client (address port)
  (let ((s (make-socket :connect :active
			:type :stream
			:address-family :internet
			:ipv6 nil)))
    (alexandria:unwind-protect-case ()
	(progn
	  (connect s address :wait nil :port port)
	  (make-instance 'client :socket s))
      (:abort
       (close s)))))
