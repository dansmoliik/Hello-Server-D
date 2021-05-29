/*
    Copied from "Usage" section of https://github.com/tchaloupka/httparsed
*/
module msg;

import httparsed;

// define our message content handler
struct Header
{
    const(char)[] name;
    const(char)[] value;
}

// Just store slices of parsed message header
struct Msg
{
    @safe pure nothrow @nogc:
    void onMethod(const(char)[] method) { this.method = method; }
    void onUri(const(char)[] uri) { this.uri = uri; }
    int onVersion(const(char)[] ver)
    {
        minorVer = parseHttpVersion(ver);
        return minorVer >= 0 ? 0 : minorVer;
    }
    void onHeader(const(char)[] name, const(char)[] value) {
        this.m_headers[m_headersLength].name = name;
        this.m_headers[m_headersLength++].value = value;
    }
    void onStatus(int status) { this.status = status; }
    void onStatusMsg(const(char)[] statusMsg) { this.statusMsg = statusMsg; }

    const(char)[] method;
    const(char)[] uri;
    int minorVer;
    int status;
    const(char)[] statusMsg;

    private {
        Header[32] m_headers;
        size_t m_headersLength;
    }

    Header[] headers() return { return m_headers[0..m_headersLength]; }
}
