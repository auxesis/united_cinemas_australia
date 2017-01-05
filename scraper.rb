require 'scraperwiki'
require 'mechanize'
require 'active_support'
require 'active_support/core_ext'
require 'pry'
require 'reverse_markdown'
require 'active_support/values/time_zone'
require 'timezone'

begin
  Timezone::Lookup.config(:google) do |c|
    c.api_key = ENV['MORPH_GOOGLE_API_KEY']
  end
rescue Timezone::Error::InvalidConfig
  puts "[info] You need to set MORPH_GOOGLE_API_KEY."
  puts "[info] Exiting!"
  exit(1)
end

class String
  def scrub
    self.gsub(/[[:space:]]/, ' ').strip # convert all utf whitespace to simple space
  end
end

def get(url)
  @agent ||= Mechanize.new
  @agent.get(url)
end

def existing_record_ids(table)
  return @cached if @cached
  @cached = ScraperWiki.select("link from #{table}").map {|r| r['link']}
rescue SqliteMagic::NoSuchTable
  []
end

def geocode(cinema)
  # FIXME(auxesis): add address details
  page = get(cinema['link'])
  script = page.search('script').find {|s| s.text =~ /google.maps.LatLng/ }.text
  script.gsub("\r","\n")[/LatLng\((.*)\)\;/, 1].split(',').map(&:to_f)
end

def timezone_from_location(lat,lng)
  Timezone.lookup(lat,lng).name
end

def current_cinema_list
  return @cinemas if @cinemas

  @cinemas ||= []

  page = get("http://www.unitedcinemas.com.au/session-times")

  cinema_links = page.search('ul.nav.navbar-nav li.dropdown a').find { |a|
    a.text =~ /Session Times/
  }.parent.search('ul li a')

  @cinemas = cinema_links.map {|a|
    {
      'name' => a.text,
      'id'   => a['href'].split('/').last,
      'link' => a['href'],
    }
  }
end

def extract_sessions(page)
  titles = page.search('tr').reject {|tr| tr.children.reject {|n| n.text? }.size == 0}

  titles.map { |title|
    text  = title.search('td').text
    links = title.search('a').map {|a| a['href']}.reject {|a| URI.parse(a).path.blank?}.uniq
    times = title.search('a').map {|a| a.text.scrub }.select {|a| a =~ /AM|PM/}.uniq
    sessions = links.zip(times)

    sessions.map {|(link, time)|
      session = {
        'link' => link,
        'time' => time,
        'title' => title.search('b').text,
        'rating' => text[/Rating: (.+)/, 1],
        'running_time' => text[/Running Time: (\d+) minutes/, 1].to_i,
      }

      cast = text[/Cast:\s*(.+)/, 1]
      session['cast'] = cast if cast
      synopsis = text[/Synopsis:\s*(.+)/, 1]
      session['synopsis'] = synopsis if synopsis

      session
    }
  }.flatten
end


def scrape_sessions(cinema, date)
  id  = cinema['id']
  url = "http://www.unitedcinemas.com.au/session_data.php?date=#{date}&l=#{id}&sort=title"
  page = get(url)

  sessions = extract_sessions(page)
  sessions.each do |session|
    Time.zone = cinema['timezone']
    session['time'] = Time.zone.parse("#{date} #{session['time']}")
    session['location'] = id
  end
end

def dates
  (Date.today..Date.today + 6).to_a.map(&:to_s)
end

def primary_key
  %w(link)
end

def scrape_cinemas
  cinemas = current_cinema_list
  puts "[info] Scraped #{cinemas.size} cinemas"
  puts "[info] There are #{existing_record_ids('cinemas').size} existing cinemas"
  new_cinemas = cinemas.select {|r| !existing_record_ids('cinemas').include?(r['link'])}
  puts "[info] There are #{new_cinemas.size} new cinemas"

  new_cinemas.map! do |cinema|
    puts "[debug] Geocoding #{cinema['name']}"
    lat, lng = geocode(cinema)
    timezone = timezone_from_location(lat,lng)
    cinema.merge({'lat' => lat, 'lng' => lng, 'timezone' => timezone})
  end

  ScraperWiki.save_sqlite(%w(id), new_cinemas, 'cinemas')

  # Then return all records, regardless if new or old
  ScraperWiki.select('* from cinemas')
end

def main
  cinemas = scrape_cinemas

  sessions = []

  cinemas.each do |cinema|
    dates.each do |date|
      puts "[info] Fetching sessions for #{cinema['name']} on #{date}"
      sessions += scrape_sessions(cinema, date)
    end
  end

  puts "[info] Scraped #{sessions.size} sessions across #{cinemas.size} cinemas"
  puts "[info] There are #{existing_record_ids('sessions').size} existing sessions"
  new_sessions = sessions.select {|r| !existing_record_ids('sessions').include?(r['link'])}
  puts "[info] There are #{new_sessions.size} new sessions"

  ScraperWiki.save_sqlite(%w(link), new_sessions, 'sessions')

  puts '[info] Done'
end

main()
