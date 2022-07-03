# hugo build layer
FROM alpine as builder
RUN apk add hugo git
RUN git clone https://github.com/k0rventen/k0rventen.github.io.git blog
WORKDIR blog
RUN git submodule init && git submodule update
RUN hugo -d dist

# nginx server
FROM caddy:latest
COPY Caddyfile /etc/caddy/Caddyfile
COPY --from=builder /blog/dist /www/blog
