FROM node:22-slim AS build
WORKDIR /app

COPY web/package*.json ./
RUN npm ci --no-audit --no-fund

COPY web/ ./
RUN npm run build

FROM nginx:alpine
ENV PORT=80

COPY --from=build /app/dist /usr/share/nginx/html
COPY web/nginx.conf /etc/nginx/templates/default.conf.template
COPY web/docker-entrypoint.sh /ascent-entrypoint.sh
RUN chmod +x /ascent-entrypoint.sh

EXPOSE 80
ENTRYPOINT ["/ascent-entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
