FROM nginx:stable-alpine

# The actual service configurations are mounted at runtime from ./nginx/conf.d.
RUN rm -f /etc/nginx/conf.d/default.conf

COPY nginx/nginx.conf /etc/nginx/nginx.conf

EXPOSE 80 443
