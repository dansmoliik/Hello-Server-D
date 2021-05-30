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
import core.sys.posix.unistd;

import msg;

import httparsed;

enum int MAX_EVENTS = 10;
enum int PORT = 8080;
enum SOCK_NONBLOCK = 0x800;
enum ulong READ_CHUNK_SIZE = 512;
enum int FDS_ARR_OFFSET = -5;
enum string REPLY_NOT_FOUND = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n";
enum string REPLY_OK = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n";

string[MAX_EVENTS] replies;

/*
 * Initialize server - listening socket and epoll.
*/
void init_server(ref int listen_sock, ref int epollfd, ref epoll_event ev, ref epoll_event* events)
{
    events = cast(epoll_event*)malloc( MAX_EVENTS * epoll_event.sizeof);

    sockaddr_in server_addr;
    server_addr.sin_family = AF_INET;
    server_addr.sin_addr.s_addr = htonl( INADDR_ANY);
    server_addr.sin_port = htons( PORT);

    if ((listen_sock = socket( AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0)) == -1)
    {
        perror( "socket error");
        exit( EXIT_FAILURE);
    }

    int flags = 1;
    setsockopt( listen_sock, SOL_SOCKET, SO_REUSEADDR, cast(void*)&flags, int.sizeof);
    setsockopt( listen_sock, IPPROTO_TCP, TCP_NODELAY, cast(void*)&flags, int.sizeof);

    if (bind( listen_sock, cast(sockaddr*)&server_addr, sockaddr.sizeof) == -1)
    {
        perror( "bind error");
        exit( EXIT_FAILURE);
    }

    if (listen( listen_sock, 32) == -1)
    {
        perror( "listen error");
        exit( EXIT_FAILURE);
    }

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
}

/*
 * Function responsible for accepting new communication and adding it to epoll.
*/
void add_new_communication_socket(int fd, int epollfd, epoll_event ev, ref sockaddr_in conn_addr, ref socklen_t addr_size)
{
    int conn_sock = accept( fd, cast(sockaddr *) &conn_addr, &addr_size);
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
}

/*
 * Function responsible for reading a whole message from a socket.
*/
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

/*
 * Function responsible for creating json reply string based on request uri.
 * If there is a parameter "name", it returns string in format of "{"hello": "<name>"}", otherwise "{}"
*/
string create_json(string uri)
{
    ptrdiff_t index_of_name_substr = indexOf( uri, "name"); // find parameter "name" in the uri
    while (index_of_name_substr != -1) // make sure it is really parameter name, not xname or namex
    {
        if ((uri[index_of_name_substr - 1] == '?' || uri[index_of_name_substr - 1] == '&') &&
        index_of_name_substr + 4 < uri.length && uri[index_of_name_substr + 4] == '=')
            break;
        index_of_name_substr = indexOf( uri, "name", index_of_name_substr + 1);
    }
    if (index_of_name_substr == -1 || index_of_name_substr + 4 >= uri.length || uri[index_of_name_substr + 4] != '=')
        return "{}\r\n"; // there is no parameter "name"

    string data_substr = uri[index_of_name_substr + 5..$]; // slice off everything before actual name
    ptrdiff_t index_of_symbol_and = indexOf( data_substr, "&"); // search for other parameters

    if (index_of_symbol_and == -1)
        return "{\"hello\":\"" ~ data_substr ~ "\"}\r\n"; // "name" is the only parameter
    return "{\"hello\":\"" ~ data_substr[0..index_of_symbol_and] ~ "\"}\r\n"; // slice off other parameters
}

/*
 * Create a reply to GET request.
*/
string create_reply_ok(string uri)
{
    string json_str = create_json( uri);
    return REPLY_OK ~ "Content-Length: " ~ to!string( json_str.length) ~ "\r\n\r\n" ~ json_str;
}

string handle_get(string uri)
{
    ptrdiff_t index_of_path_beginning = indexOf( uri, "/hello");
    if (index_of_path_beginning == -1 || (index_of_path_beginning + 6 < uri.length && uri[index_of_path_beginning + 6] != '?'))
        return REPLY_NOT_FOUND; // if path is someething else than "/hello"
    return create_reply_ok( uri);
}

/*
 * Create a reply based on the "msg" method and uri.
*/
string create_reply_from_msg(string msg)
{
    string reply;
    auto parser = initParser!Msg();
    parser.parseRequest( msg);
    debug writeln( "SERVER:\tCreating response to method: ", parser.method);

    switch (parser.method)
    {
        case "GET":
        return handle_get( to!string( parser.uri));

        default:
        return REPLY_NOT_FOUND;
    }
}

/*
 * Save a reply to array of replies so it can be later sent.
*/
void save_reply(int fd, string reply)
{
    replies[fd + FDS_ARR_OFFSET] = reply;
    debug writeln( "SERVER:\tReply saved at index: ", fd + FDS_ARR_OFFSET);
}

/*
 * The main function responsible for reading a message and creating a reply to it.
*/
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

    save_reply( fd, reply); // reply is saved here and it is sent later
    //Set Write Action Events for Annotation
    ev.data.fd = fd;
    ev.events=EPOLLOUT;
    epoll_ctl( epollfd,EPOLL_CTL_MOD, fd, &ev);
}

/*
 * Function responsible for sending a reply.
*/
void send_reply(int fd, int epollfd, epoll_event ev)
{

    string reply = replies[fd + FDS_ARR_OFFSET];
    debug writeln( "SERVER:\tSending reply: ", reply);

    send( fd, cast(char*)reply, reply.length, 0);

    ev.data.fd = fd;
    if (epoll_ctl( epollfd, EPOLL_CTL_DEL, fd, &ev) == -1) {
        perror( "epoll_ctl: del conn_sock");
        exit( EXIT_FAILURE);
    }
    close( fd);
    debug writeln( "SERVER:\tClosed: :", fd);
}

unittest
{
    string uri = "/";
    string json_str = create_json( uri);
    assert(json_str == "{}\r\n");
}

unittest
{
    string uri = "/?name";
    string json_str = create_json( uri);
    assert(json_str == "{}\r\n");
}

unittest
{
    string uri = "/?namel=xxx";
    string json_str = create_json( uri);
    assert(json_str == "{}\r\n");
}

unittest
{
    string uri = "/?param=name";
    string json_str = create_json( uri);
    assert(json_str == "{}\r\n");
}

unittest
{
    string uri = "/?name=xxx";
    string json_str = create_json( uri);
    assert(json_str == "{\"hello\":\"xxx\"}\r\n");
}

unittest
{
    string uri = "/?param=ahoj&name=xxx";
    string json_str = create_json( uri);
    assert(json_str == "{\"hello\":\"xxx\"}\r\n");
}

unittest
{
    string uri = "/?name=xxx&param=ahoj";
    string json_str = create_json( uri);
    assert(json_str == "{\"hello\":\"xxx\"}\r\n");
}

unittest
{
    string msg = "GET /foo HTTP/1.1\r\nHost: 127.0.0.1:8090\r\n\r\n";
    string reply = create_reply_from_msg( msg);

    auto resParser = initParser!Msg();
    resParser.parseResponse( reply);
    assert(resParser.status == 404);
    assert(resParser.statusMsg == "Not Found");
}

unittest
{
    string msg = "GET /?name=xxx HTTP/1.1\r\nHost: 127.0.0.1:8090\r\n\r\n";
    string reply = create_reply_from_msg( msg);

    auto resParser = initParser!Msg();
    resParser.parseResponse( reply);
    assert(resParser.status == 404);
    assert(resParser.statusMsg == "Not Found");
}

unittest
{
    string msg = "GET /helloo?name=xxx HTTP/1.1\r\nHost: 127.0.0.1:8090\r\n\r\n";
    string reply = create_reply_from_msg( msg);

    auto resParser = initParser!Msg();
    resParser.parseResponse( reply);
    assert(resParser.status == 404);
    assert(resParser.statusMsg == "Not Found");
}

unittest
{
    string msg = "GET /hello?myname=xXx&bla=blabla&mynamemy=xXx HTTP/1.1\r\nHost: 127.0.0.1:8090\r\n\r\n";
    string reply = create_reply_from_msg( msg);
    assert(indexOf( reply, "{}") != -1);

    auto resParser = initParser!Msg();
    resParser.parseResponse( reply);
    assert(resParser.status == 200);
    assert(resParser.statusMsg == "OK");
}

unittest
{
    string msg = "GET /hello HTTP/1.1\r\nHost: 127.0.0.1:8090\r\n\r\n";
    string reply = create_reply_from_msg( msg);
    assert(indexOf( reply, "{}") != -1);

    auto resParser = initParser!Msg();
    resParser.parseResponse( reply);
    assert(resParser.status == 200);
    assert(resParser.statusMsg == "OK");
}

unittest
{
    string msg = "GET /hello? HTTP/1.1\r\nHost: 127.0.0.1:8090\r\n\r\n";
    string reply = create_reply_from_msg( msg);
    assert(indexOf( reply, "{}") != -1);

    auto resParser = initParser!Msg();
    resParser.parseResponse( reply);
    assert(resParser.status == 200);
    assert(resParser.statusMsg == "OK");
}

unittest
{
    string msg = "GET /hello?myname=xxx HTTP/1.1\r\nHost: 127.0.0.1:8090\r\n\r\n";
    string reply = create_reply_from_msg( msg);
    assert(indexOf( reply, "{}") != -1);

    auto resParser = initParser!Msg();
    resParser.parseResponse( reply);
    assert(resParser.status == 200);
    assert(resParser.statusMsg == "OK");
}

unittest
{
    string msg = "GET /hello?name=xxx HTTP/1.1\r\nHost: 127.0.0.1:8090\r\n\r\n";
    string reply = create_reply_from_msg( msg);
    assert(indexOf( reply, "{\"hello\":\"xxx\"}") != -1);

    auto resParser = initParser!Msg();
    resParser.parseResponse( reply);
    assert(resParser.status == 200);
    assert(resParser.statusMsg == "OK");
}

unittest
{
    string msg = "POST /?name=xxx HTTP/1.1\r\nHost: 127.0.0.1:8090\r\n\r\n";
    string reply = create_reply_from_msg( msg);
    assert(indexOf( reply, "hello") == -1);

    auto resParser = initParser!Msg();
    resParser.parseResponse( reply);
    assert(resParser.status == 404);
    assert(resParser.statusMsg == "Not Found");
}
