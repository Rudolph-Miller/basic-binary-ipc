(in-package "BASIC-BINARY-IPC")

(define-posix-system-call (%ff-epoll-create "epoll_create") :int
  (size :int))

(define-posix-system-call (%ff-epoll-ctl "epoll_ctl") :int
  (epfd :int)
  (op epoll-operation)
  (fd :int)
  (event (:pointer (:struct epoll-event))))

(define-posix-system-call (%ff-epoll-wait "epoll_wait") :int
  (epfd :int)
  (events (:pointer (:struct epoll-event)))
  (maxevents :int)
  (timeout :int))
