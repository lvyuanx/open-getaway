FROM nginx:stable-alpine

# Runtime configuration and static gateway pages are mounted by Compose.
RUN rm -f /etc/nginx/conf.d/default.conf

COPY nginx/nginx.conf /etc/nginx/nginx.conf
COPY nginx/html /usr/share/nginx/html

EXPOSE 80 443
