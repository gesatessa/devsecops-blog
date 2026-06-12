# devsecops-blog

## docker dev

```sh
docker compose up --build

curl -I localhost:3000
# HTTP/1.1 200 OK
# Vary: Origin
# Content-Type: text/html
# Cache-Control: no-cache
# Etag: W/"410-dc8GlWxr3oBZmjjsxWHBp1xIoCk"
# Date: Fri, 12 Jun 2026 11:42:57 GMT
# Connection: keep-alive
# Keep-Alive: timeout=5
```


Now you can access the app in `http://54.160.201.251:3000/`

NOTE: The `PORTS` column in `docker p`s shows how ports inside the container are exposed to your host machine.
For example, for our `frontend`:
```yml
PORTS
0.0.0.0:3000->3000/tcp, [::]:3000->3000/tcp, 5173/tcp
```

Here's what each part means.
1) `0.0.0.0:3000->3000/tcp`
Host port 3000 is forwarded to port 3000 inside the container over TCP. Accessible from any IPv4 interface on your machine.

2) `[::]:3000->3000/tcp`
The same mapping for IPv6. Accessible on port 3000 via IPv6 addresses.

3) `5173/tcp`
The container exposes port 5173, but it is not published to the host. Other containers on the same Docker network may be able to use it, but your host cannot connect to it directly.


### Visual representation
```yml
                Host machine
         +-----------------------+
         |                       |
Browser -> localhost:3000        |
         |        |              |
         |        v              |
         +-----------------------+
                  |
                  | port mapping
                  v
         +-----------------------+
         | Docker container      |
         |                       |
         | 3000/tcp  <--- app    |
         | 5173/tcp  <--- exposed only internally
         +-----------------------+
```

## frontend

```js
// frontend/vite.config.js 

import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  server: {
    host: '0.0.0.0', // only controls where Vite listens.
    port: 3000,
    proxy: {
      '/api': {
        target: 'http://backend:5000', // controls where Vite forwards API requests
        changeOrigin: true,
      },
    },
  },
  preview: {
    host: '0.0.0.0',
    port: 3000,
  },
});
```

Test:
```sh
docker compose exec frontend wget -qO- http://backend:5000/api/health
# {"status":"ok","message":"Jerney API is vibing ✨"}%
```

## db

```sh
docker compose exec postgres psql -U jerney_user -d jerney_db
# psql (16.14)
# Type "help" for help.

# jerney_db=# \dt
#             List of relations
#  Schema |   Name   | Type  |    Owner    
# --------+----------+-------+-------------
#  public | comments | table | jerney_user
#  public | posts    | table | jerney_user
```
