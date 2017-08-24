#' LSF scheduler functions
#'
#' Derives from QSys to provide LSF-specific functions
SSH = R6::R6Class("SSH",
    inherit = QSys,

    public = list(
        initialize = function(fun, const, export, seed) {
            if (is.null(SSH$host))
                stop("SSH host not set")

            super$initialize()
            local_port = private$port
            remote_port = sample(50000:55000, 1)

            # set forward and run ssh.r (send port, master)
            rev_tunnel = sprintf("%i:localhost:%i", remote_port, local_port)
            tunnel = sprintf("tcp://localhost:%i", remote_port)
            rcmd = sprintf("R --no-save --no-restore -e \\
                           'clustermq:::proxy(\"%s\")' > %s 2>&1", tunnel,
                           getOption("clustermq.ssh.log", default="/dev/null"))
            ssh_cmd = sprintf('ssh -f -R %s %s "%s"', rev_tunnel, SSH$host, rcmd)

            # wait for ssh to connect
            message(sprintf("Connecting %s via SSH ...", SSH$host))
            system(ssh_cmd, wait=TRUE, ignore.stdout=TRUE, ignore.stderr=TRUE)
            private$init_proxy()
        },

        submit_job = function(template=list(), log_worker=FALSE) {
            if (is.null(private$master))
                stop("Need to call listen_socket() first")

            # get the parent call and evaluate all arguments
            call = match.call()
            evaluated = lapply(call[2:length(call)], function(arg) {
                if (is.call(arg) || is.name(arg))
                    eval(arg, envir=parent.frame(2))
                else
                    arg
            })

            # forward the submit_job call via ssh
            call[2:length(call)] = evaluated
            rzmq::send.socket(private$socket, data = list(id="PROXY_CMD", exec=call))

            msg = rzmq::receive.socket(private$socket)
            if (msg$id != "PROXY_CMD" || class(msg$reply) == "try-error")
                stop(msg)
        },

        cleanup = function(dirty=FALSE) {
            #FIXME: this may still get worker results when dirty=TRUE
            # need to loop over results until we get ssh_proxy
            rzmq::receive.socket(private$socket)
            rzmq::send.socket(private$socket, data=list(id="PROXY_STOP"))
        }
    ),

	private = list(
        # Exchange init messages with proxy
        init_proxy = function() {
            msg = rzmq::receive.socket(private$socket)
            if (msg$id != "PROXY_UP")
                stop("Establishing connection failed")

            # send common data to ssh
            message("Sending common data ...")
            rzmq::send.socket(private$socket,
                              data = list(fun=fun, const=const,
                                          export=export, seed=seed))
            msg = rzmq::receive.socket(private$socket)
            if (msg$id != "PROXY_READY")
                stop("Sending failed")

            private$set_common_data(redirect=msg$data_url)
        }
	)
)

# Static method, process scheduler options and return updated object
SSH$setup = function() {
    host = getOption("clustermq.ssh.host")
    if (length(host) == 0) {
        packageStartupMessage("* Option 'clustermq.ssh.host' not set, ",
                "trying to use it will fail")
        packageStartupMessage("--- see: https://github.com/mschubert/clustermq/wiki/SSH")
    } else {
        SSH$host = host
    }
    SSH
}
