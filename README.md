Scraper for [United Cinemas](http://www.unitedcinemas.com.au/)'s session times.

The scraper fetches session times across all United Cinema locations from now until 7 days from now.

This scraper [runs on Morph](https://morph.io/auxesis/united_cinemas_australia). To get started [see Morph's documentation](https://morph.io/documentation).

## Developing

Ensure you have Git, Ruby, and Bundler set up the scraper locally, then run:

```
git clone https://github.com/auxesis/united_cinemas_australia.git
cd united_cinemas_australia
bundle install
```

Ensure you enable the [Google Maps Time Zone API](https://console.developers.google.com/apis/api/timezone_backend/overview).

Then get yourself a [Google Maps API key](https://console.developers.google.com/apis/credentials), and export it:

```
export MORPH_GOOGLE_API_KEY=AIabSguDVmM6dxBHEeBGM-AN1z8R9p9xBG4t102q
```

Then run the scraper:

```
bundle exec ruby scraper.rb
```
