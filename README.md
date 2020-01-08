# Hilding bot

*A simple Twitter bot that posts random images by Swedish photographer Hilding Mickelsson, using the K-samsök/SOCH API.*

## About

This is the code that runs the [@hilding_bot](https://twitter.com/hilding_bot) Twitter bot. It posts random images by Swedish photographer [Hilding Mickelsson](https://sv.wikipedia.org/wiki/Hilding_Mickelsson), using the [K-samsök/SOCH](https://www.raa.se/ksamsok) API. Aside from a few parts that are peculiar to that particular collection of photos, the code is otherwise fairly generic and could very easily be adapted to find and post any set of photos from K-samsök/SOCH, simply by changing the CQL search query at the top of `hilding_cache.pl`.

The [archive of Hilding Mickelsson's photographs](https://halsinglandsmuseum.se/samlingar/bildarkiv/hilding-mickelsson/) is curated by [Hälsinglands Museum](https://halsinglandsmuseum.se/), who publish them under a [CC BY-NC](http://creativecommons.org/licenses/by-nc/4.0/) license on [DigitaltMuseum](https://digitaltmuseum.se/), from where they are aggregated to K-samsök/SOCH.

## Configuration and usage

You'll need a modern (≥5.16) version of Perl (I suggest using [Perlbrew](https://perlbrew.pl/).) The scripts use a few non-core modules which you'll also need to install: run `perl -c` on each of the scripts (or just check the `use` directives at the top) and install whatever it complains about with [`cpanm`](https://metacpan.org/pod/App::cpanminus) until it stops complaining. 😊 (Perlbrew lets you easily bootstrap `cpanm` with `perlbrew install-cpanm`.)

There are two scripts:

- `hilding_bot.pl` is the Twitter bot itself. It fetches RDF data from K-samsök/SOCH and image data from DigitaltMuseum, mungs it a bit to make a suitable tweet text, and posts the image and data to Twitter.  
To use it, create a new application in the [Twitter Developer site](https://developer.twitter.com/en/apps). Copy `oauth.yml.example` to `oauth.yml` and edit it to add your consumer key and secret. `hilding_bot.pl` will prompt you to authenticate the first time it is run on the command line, and save an access token and secret for future authentication.  
After the first interactive run for authentication, `hilding_bot.pl` is intended to be run as a scheduled `cron` job.

- `hilding_cache.pl` is a support script that generates and maintains a list of K-samsök/SOCH URIs matching its search criteria in `uri-cache.yml`. This lets the bot quickly pick a URI at random while excluding those it has already tweeted (which it saves to `used-uris.yml`). `hilding_cache.pl` parallelises its search, but even so it can take a few minutes to run if the search results in a large number of hits; I suggest setting a weekly `cron` job.  
The caches need to be primed before `hilding_bot.pl` is run for the first time: run `hilding_cache.pl` and when it's finished, copy `uri-cache.yml` to `used-uris.yml`; the bot will take care of the book-keeping after that.

If you don't care about potentially posting the same thing twice, you could dispense with `hilding_cache.pl` and the YAML caches entirely, and instead adapt `hilding_bot.pl` to just pick a URI at random from the K-samsök/SOCH search result at run-time.
