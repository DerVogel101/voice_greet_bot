FROM dart:stable AS build

WORKDIR /app

COPY pubspec.yaml pubspec.lock ./
RUN dart pub get --enforce-lockfile

COPY . .
RUN dart compile exe lib/main.dart -o /app/build/voice_greet_bot

FROM debian:bookworm-slim AS runtime

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=build /app/build/voice_greet_bot /app/voice_greet_bot

CMD ["/app/voice_greet_bot"]
