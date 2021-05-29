import std.stdio;
import std.conv;
import std.string;

import core.stdc.stdio;
import core.stdc.stdlib;
import core.sys.linux.netinet.tcp;
import core.sys.posix.netinet.in_;
import core.sys.posix.sys.socket;
import core.sys.linux.epoll;
import core.stdc.string;
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
enum ulong READ_CHUNK_SIZE = 512;
enum int FDS_ARR_OFFSET = -5;
enum string REPLY_NOT_FOUND = "HTTP/1.1 404 Not Found\r\n\r\n";
enum string REPLY_OK = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n";

string[MAX_EVENTS] replies;

ssize_t recv_msg(int fd, ref string msg)
{
    ssize_t total_size = 0;
    ssize_t size_recv;
    char *chunk = cast(char*)malloc( READ_CHUNK_SIZE);
    msg = "";

    while ((size_recv =  recv( fd, chunk, READ_CHUNK_SIZE, 0) ) > 0)
    {
        total_size += size_recv;
        msg ~= to!string( chunk);
        //debug writeln( "\t", to!string( chunk));
        memset( chunk , 0, READ_CHUNK_SIZE);    //clear the variable chunk
    }
    return total_size;
}

string create_json(string uri)
{
    ptrdiff_t index_of_name_substr = indexOf( uri, "name"); // find parameter "name" in the uri
    if (index_of_name_substr == -1 || index_of_name_substr + 1 >= uri.length || uri[index_of_name_substr + 1] != '=')
        return "{}"; // there is no parameter "name"
    string data_substr = uri[index_of_name_substr + 5..$]; // slice off everything before actual name
    ptrdiff_t index_of_symbol_and = indexOf( data_substr, "&"); // search for other parameters
    if (index_of_symbol_and == -1) return "{\"hello\":\"" ~ data_substr ~ "\"}"; // "name" is the only parameter
    return "{\"hello\":\"" ~ data_substr[0..index_of_symbol_and] ~ "\"}"; // slice off other parameters
}

string create_reply_ok(string uri)
{
    string json_str = create_json( uri);
    string reply = REPLY_OK ~ "Content-Length: " ~ to!string( json_str.length + 2) ~ "\r\n\r\n"; // 2 extra white spaces
    reply = reply ~ json_str ~ "\r\n";
    return reply;
}

string create_reply_from_msg(string msg)
{
    string reply;
    auto parser = initParser!Msg();
    parser.parseRequest( msg);

    debug writeln( "SERVER:\tCreating response to method: ", parser.method);

    switch (parser.method)
    {
        case "GET":
        return create_reply_ok( to!string( parser.uri));
        default:
        return REPLY_NOT_FOUND;
    }
}

void save_reply(int fd, string reply)
{
    replies[fd + FDS_ARR_OFFSET] = reply;

    debug writeln( "SERVER:\tReply saved at index: ", fd + FDS_ARR_OFFSET);
}

void receive_msg(int fd, int epollfd, epoll_event ev)
{
    ssize_t msg_size;
    string msg, reply;

    debug writeln( "SERVER:\tReceiving message from: ", fd);

    msg_size = recv_msg( fd, msg);

    debug writeln( "SERVER:\tTotal msg length:", msg_size);
    debug writeln( "SERVER:\tMessage received: ", msg);

    reply = create_reply_from_msg( msg);

    debug writeln( "SERVER:\tCreated reply: ", reply);

    save_reply( fd, reply);

    ev.data.fd = fd;
    //Set Write Action Events for Annotation

    ev.events=EPOLLOUT;
    epoll_ctl( epollfd,EPOLL_CTL_MOD, fd, &ev);
}

int main()
{
    writeln( "SERVER: SERVER STARTED");

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
        perror( "socket error");
        exit( EXIT_FAILURE);
    }
    debug writeln( "SERVER: Socket created");

    int flags = 1;
    setsockopt( listen_sock, SOL_SOCKET, SO_REUSEADDR, cast(void*)&flags, int.sizeof);
    setsockopt( listen_sock, IPPROTO_TCP, TCP_NODELAY, cast(void*)&flags, int.sizeof);

    if (bind( listen_sock, cast(sockaddr*)&server_addr, sockaddr.sizeof) == -1)
    {
        perror( "bind error");
        exit( EXIT_FAILURE);
    }
    debug writeln( "SERVER: Socket bound to local address");

    if (listen( listen_sock, 32) == -1)
    {
        perror( "listen error");
        exit( EXIT_FAILURE);
    }
    debug writeln( "SERVER: Socket listening");

    epollfd = epoll_create1( 0);
    if (epollfd == -1) {
        perror( "epoll_create1");
        exit( EXIT_FAILURE);
    }

    ev.events = EPOLLIN;
    ev.data.fd = listen_sock;
    if (epoll_ctl( epollfd, EPOLL_CTL_ADD, listen_sock, &ev) == -1) {
        perror( "epoll_ctl: listen_sock");
        exit( EXIT_FAILURE);
    }

    for (;;)
    {
        debug writeln( "SERVER: Start waiting");
        nfds = epoll_wait( epollfd, events, MAX_EVENTS, -1);
        debug writeln( "SERVER: Stopped waiting");
        if (nfds == -1) {
            perror( "epoll_wait");
            exit( EXIT_FAILURE);
        }

        for (int n = 0; n < nfds; ++n)
        {
            if (events[n].data.fd == listen_sock)
            {
                conn_sock = accept( listen_sock, cast(sockaddr *) &conn_addr, &addr_size);
                if (conn_sock == -1) {
                    perror( "accept");
                    exit( EXIT_FAILURE);
                }
                debug writeln( "SERVER: Got connection from: ", inet_ntoa( conn_addr.sin_addr), ":", ntohs( conn_addr.sin_port));

                if (fcntl( conn_sock, F_SETFL, fcntl( conn_sock, F_GETFL, 0) | O_NONBLOCK) == -1){
                    perror( "calling fcntl");
                    exit( EXIT_FAILURE);
                }
                ev.events = EPOLLIN;
                ev.data.fd = conn_sock;
                if (epoll_ctl( epollfd, EPOLL_CTL_ADD, conn_sock, &ev) == -1) {
                    perror( "epoll_ctl: add conn_sock");
                    exit( EXIT_FAILURE);
                }
            } else if (events[n].events&EPOLLIN)
            {
                debug writeln( "SERVER: EPOLLIN ",events[n].data.fd);

                receive_msg( events[n].data.fd, epollfd, ev);
            }
            else if (events[n].events&EPOLLOUT) // If there is data to send
                {
                    debug writeln( "SERVER: EPOLLOUT ", events[n].data.fd);

                    string reply = replies[events[n].data.fd + FDS_ARR_OFFSET];

                    debug writeln( "SERVER:\tSending reply: ", reply);

                    send( events[n].data.fd, cast(char*)reply, reply.length, 0);

                    ev.data.fd = events[n].data.fd;
                    if (epoll_ctl( epollfd, EPOLL_CTL_DEL, events[n].data.fd, &ev) == -1) {
                        perror( "epoll_ctl: del conn_sock");
                        exit( EXIT_FAILURE);
                    }
                    close( events[n].data.fd);
                    debug writeln( "SERVER:\tClosed: :", events[n].data.fd);
                }
        }
    }
}
