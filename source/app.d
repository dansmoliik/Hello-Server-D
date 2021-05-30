/**
 * Application written in D Programming Language showing a simple server.
*/

import std.stdio;
import core.stdc.stdlib;
import core.sys.linux.netinet.tcp;
import core.sys.posix.netinet.in_;
import core.sys.linux.epoll;

import hello_server;

int main()
{
    writeln( "SERVER: SERVER STARTED");

    int listen_sock, conn_sock, nfds, epollfd;
    sockaddr_in conn_addr;
    socklen_t addr_size;
    epoll_event ev;
    epoll_event* events;

    init_server( listen_sock, epollfd, ev, events);
    debug writeln( "SERVER: INITIALIZED");

    for (;;)
    {
        debug writeln( "SERVER: Start waiting");
        nfds = epoll_wait( epollfd, events, MAX_EVENTS, -1);
        if (nfds == -1) {
            perror( "epoll_wait");
            exit( EXIT_FAILURE);
        }
        debug writeln( "SERVER: Stopped waiting");

        for (int n = 0; n < nfds; ++n)
        {
            if (events[n].data.fd == listen_sock)
            {
                debug writeln( "SERVER: NEW CONNECTION");
                add_new_communication_socket( listen_sock, epollfd, ev, conn_addr, addr_size);
            } else if (events[n].events&EPOLLIN)
            {
                debug writeln( "SERVER: EPOLLIN ",events[n].data.fd);
                receive_msg( events[n].data.fd, epollfd, ev);
            }
            else if (events[n].events&EPOLLOUT)
                {
                    debug writeln( "SERVER: EPOLLOUT ", events[n].data.fd);
                    send_reply( events[n].data.fd, epollfd, ev);
                }
        }
    }
}
