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
  @mechanize_cache ||= {}
  @agent ||= Mechanize.new
  @agent.history.max_size = 0

  if @mechanize_cache[url]
    puts "[debug] Requesting [cache hit] #{url}"
    return @mechanize_cache[url]
  else
    puts "[debug] Requesting #{url}"
    @mechanize_cache[url] = @agent.get(url)
  end
end

def existing_record_ids(table)
  @cached ||= {}
  if @cached[table]
    return @cached[table]
  else
    @cached[table] = ScraperWiki.select("link from #{table}").map {|r| r['link']}
  end
rescue SqliteMagic::NoSuchTable
  []
end

def extract_address(cinema)
  page = get(cinema['link'])

  well = page.search('div.well h3#session-details-title').first.parent.children
  body = well.reject {|c| c.name == 'h3'}.map {|c| c.text.strip}
  address = body.reject {|c| c.blank? || c =~ /^Phone/}.join(', ')
  cinema['address'] = address
end

def extract_lat_lng(cinema)
  page = get(cinema['link'])
  script = page.search('script').find {|s| s.text =~ /google.maps.LatLng/}.text
  lat, lng = script.gsub("\r","\n")[/LatLng\((.*)\)\;/, 1].split(',').map(&:to_f)
  cinema['lat'], cinema['lng'] = lat, lng
end

def determine_timezone(cinema)
  lat, lng = [ cinema['lat'], cinema['lng'] ]
  cinema['timezone'] = Timezone.lookup(lat,lng).name
end

def extract_information(cinema)
  page = get(cinema['link'])
  tab  = page.search('div#information').children
  cinema['information'] = ReverseMarkdown.convert(tab.search('p').to_s)
end

def extract_social(cinema)
  page = get(cinema['link'])
  tab = page.search('div#social').children
  cinema['facebook'] = tab.search('div.fb-page').first['data-href']
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

def add_attribute_if_match(attrs, attr, match)
  attrs[attr] = match if match
  attrs
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
        'title' => title.search('b').text.strip,
        'rating' => text[/Rating: (.+)/, 1],
        'running_time' => text[/Running Time: (\d+) minutes/, 1].to_i,
      }

      add_attribute_if_match(session, 'cast', text[/Cast:\s*(.+)/, 1])
      add_attribute_if_match(session, 'synopsis', text[/Synopsis:\s*(.+)/, 1])
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
    session['location'] = id # where the session is happening
  end
end

def dates
  start  = ENV['MORPH_START_DATE']  ? Date.parse(ENV['MORPH_START_DATE']) : Date.today
  finish = ENV['MORPH_FINISH_DATE'] ? Date.parse(ENV['MORPH_FINISH_DATE']) : Date.today + 6

  (start..finish).to_a.map(&:to_s)
end

def scrape_cinemas
  cinemas = current_cinema_list
  puts "[info] Scraped #{cinemas.size} cinemas"
  puts "[info] There are #{existing_record_ids('cinemas').size} existing cinemas"
  new_cinemas = cinemas.select {|r| !existing_record_ids('cinemas').include?(r['link'])}
  puts "[info] There are #{new_cinemas.size} new cinemas"

  new_cinemas.each do |cinema|
    extract_address(cinema)
    extract_lat_lng(cinema)
    determine_timezone(cinema)
    extract_information(cinema)
    extract_social(cinema)
  end

  ScraperWiki.save_sqlite(%w(link), new_cinemas, 'cinemas')

  # Then return all records, regardless if new or old
  ScraperWiki.select('* from cinemas')
end

def main
  cinemas = scrape_cinemas

  sessions = []
  threads = []
  queue = Queue.new

  cinemas.each do |cinema|
    dates.each do |date|
      queue << [ cinema, date ]
    end
  end

  10.times do
    threads << Thread.new {
      begin
        while job = queue.pop(true) do
          cinema, date = job
          puts "[info] Fetching sessions for #{cinema['name']} on #{date}"
          sessions += scrape_sessions(cinema, date)
        end
      rescue ThreadError
      end
    }
  end

  threads.each(&:join)

  puts "[info] Scraped #{sessions.size} sessions across #{cinemas.size} cinemas"
  puts "[info] There are #{existing_record_ids('sessions').size} existing sessions"
  new_sessions = sessions.select {|r| !existing_record_ids('sessions').include?(r['link'])}
  puts "[info] There are #{new_sessions.size} new sessions"

  ScraperWiki.save_sqlite(%w(link), new_sessions, 'sessions')

  puts '[info] Done'
end

main()
