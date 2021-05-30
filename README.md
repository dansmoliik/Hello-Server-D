# Hello-Server-D
Simple server responding to HTTP GET requests in D language.

Server responses with status 200 to GET requests to paths /hello and 404 any other path or request method.

If a request contains an optional parameter "name", it returns json in the format of {"hello":"```<name>```"}

## Test

Return 200 OK and content is {"hello":"karel"}
```bash
curl "http://localhost:8080/hello?name=karel" -v
```

Return 200 OK and content is {"hello":"karel"}
```bash
curl "http://localhost:8080/hello?param1=hello&name=karel&param2=world" -v
```

Return 200 OK and content is {}
```bash
curl "http://localhost:8080/hello" -v
```

Return 200 OK and content is {}
```bash
curl "http://localhost:8080/hello?xname=xxx&namex=xxx" -v
```

Return 404 Not Found and no content
```bash
curl "http://localhost:8080/hellooo" -v
```

Return 404 Not Found and no content
```bash
curl "http://localhost:8080/hello?name=karel" -X POST -v
```