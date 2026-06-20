FROM dart:stable AS build

WORKDIR /app

COPY pubspec.yaml pubspec.lock ./
RUN dart pub get --enforce-lockfile

COPY . .
RUN mkdir -p /app/build \
    && dart run nyxx_commands:compile --no-compile -o /app/build/voice_greet_bot.g.dart lib/main.dart \
    && dart compile exe /app/build/voice_greet_bot.g.dart -o /app/build/voice_greet_bot

FROM dart:stable AS runtime

WORKDIR /app

COPY --from=build /app/build/voice_greet_bot /app/voice_greet_bot

CMD ["/app/voice_greet_bot"]
