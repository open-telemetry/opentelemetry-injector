FROM debian:12

RUN apt-get update
RUN apt install -y ruby build-essential

RUN apt-get install -y wget ruby-dev

RUN wget https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v0.128.0/otelcol-contrib_0.128.0_linux_amd64.deb
RUN dpkg -i otelcol-contrib_0.128.0_linux_amd64.deb

COPY instrumentation/dist/*.deb injector.deb

RUN dpkg -i injector.deb

RUN echo /usr/lib/opentelemetry/libotelinject.so >> /etc/ld.so.preload

RUN gem install sinatra rackup puma

COPY packaging/tests/ruby/test.sh test.sh
COPY packaging/tests/ruby/main.rb main.rb
COPY packaging/tests/ruby/Gemfile Gemfile
COPY packaging/tests/ruby/Gemfile.lock Gemfile.lock

CMD ["./test.sh"]