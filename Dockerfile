# Builds the Flutter web app and the relay into one small container.
# Deployable as-is on Render / Fly / Railway / any Docker host.
FROM ghcr.io/cirruslabs/flutter:stable AS build
WORKDIR /app
COPY . .
RUN flutter pub get && flutter build web --no-web-resources-cdn
RUN dart compile exe relay/relay_server.dart -o /app/relay_server

FROM debian:bookworm-slim
WORKDIR /app
COPY --from=build /app/relay_server ./relay_server
COPY --from=build /app/build/web ./build/web
ENV PORT=8080
EXPOSE 8080
CMD ["./relay_server"]
