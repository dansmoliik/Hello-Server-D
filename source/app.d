import std.stdio;

import core.stdc.stdio;
import core.stdc.stdlib;
import core.sys.linux.netinet.tcp;
import core.sys.posix.netinet.in_;
import core.sys.posix.sys.socket;
import core.sys.linux.epoll;

import core.sys.linux.fcntl;
import core.sys.linux.errno;
import core.sys.posix.unistd;

import std.conv : emplace;
import std.typecons : BitFlags;

import msg;

import httparsed;

enum int MAX_EVENTS = 10;
enum int PORT = 8080;
enum SOCK_NONBLOCK = 0x800;

void respond(int fd, int epollfd, epoll_event ev)
{
    debug writeln("\tResponding to: ", fd);

    if (epoll_ctl( epollfd, EPOLL_CTL_DEL, fd, &ev) == -1) {
        perror( "epoll_ctl: del conn_sock");
        exit(EXIT_FAILURE);
    }
    close(fd);
    debug writeln("\tClosed: :", fd);
}

int main()
{
    writeln("SERVER STARTED");

    epoll_event ev;
    auto events = cast(epoll_event*)malloc( MAX_EVENTS * epoll_event.sizeof);
    int listen_sock, conn_sock, nfds, epollfd;
    sockaddr_in server_addr, conn_addr;
    socklen_t addr_size;

    server_addr.sin_family = AF_INET;
    server_addr.sin_addr.s_addr = htonl( INADDR_ANY);
    server_addr.sin_port = htons( PORT);

    if ((listen_sock = socket( AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0)) == -1)
    {
        perror("socket error");
        exit(EXIT_FAILURE);
    }
    debug writeln("Socket created");

    int flags = 1;
    setsockopt(listen_sock, SOL_SOCKET, SO_REUSEADDR, cast(void*)&flags, int.sizeof);
    setsockopt(listen_sock, IPPROTO_TCP, TCP_NODELAY, cast(void*)&flags, int.sizeof);

    if (bind(listen_sock, cast(sockaddr*)&server_addr, sockaddr.sizeof) == -1)
    {
        perror("bind error");
        exit(EXIT_FAILURE);
    }
    debug writeln("Socket bound to local address");

    if (listen(listen_sock, 32) == -1)
    {
        perror("listen error");
        exit(EXIT_FAILURE);
    }
    debug writeln("Socket listening");

    epollfd = epoll_create1( 0);
    if (epollfd == -1) {
        perror( "epoll_create1");
        exit(EXIT_FAILURE);
    }

    ev.events = EPOLLIN;
    ev.data.fd = listen_sock;
    if (epoll_ctl( epollfd, EPOLL_CTL_ADD, listen_sock, &ev) == -1) {
        perror( "epoll_ctl: listen_sock");
        exit( EXIT_FAILURE);
    }

    for (;;) {
        debug writeln("Main cycle: start waiting");
        nfds = epoll_wait( epollfd, events, MAX_EVENTS, -1);
        debug writeln("Main cycle: stopped waiting");
        if (nfds == -1) {
            perror( "epoll_wait");
            exit(EXIT_FAILURE);
        }

        for (int n = 0; n < nfds; ++n) {
            if (events[n].data.fd == listen_sock) {
                conn_sock = accept( listen_sock,
                cast(sockaddr *) &conn_addr, &addr_size);
                if (conn_sock == -1) {
                    perror( "accept");
                    exit(EXIT_FAILURE);
                }

                if (fcntl(conn_sock, F_SETFL, fcntl(conn_sock, F_GETFL, 0) | O_NONBLOCK) == -1){
                    perror( "calling fcntl");
					exit(EXIT_FAILURE);
                }
                ev.events = EPOLLIN | EPOLLET;
                ev.data.fd = conn_sock;
                if (epoll_ctl( epollfd, EPOLL_CTL_ADD, conn_sock, &ev) == -1) {
                    perror( "epoll_ctl: add conn_sock");
					exit(EXIT_FAILURE);
                }
            } else {
                respond(events[n].data.fd, epollfd, ev);
            }
        }
    }
}
