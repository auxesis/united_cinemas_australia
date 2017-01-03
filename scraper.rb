require 'scraperwiki'
require 'mechanize'
require 'active_support'
require 'active_support/core_ext'
require 'pry'
require 'reverse_markdown'

class String
  def scrub
    self.gsub(/[[:space:]]/, ' ').strip # convert all utf whitespace to simple space
  end
end

def get(url)
  @agent ||= Mechanize.new
  @agent.get(url)
end

def existing_record_ids
  return @cached if @cached
  @cached = ScraperWiki.select('link from data').map {|r| r['link']}
rescue SqliteMagic::NoSuchTable
  []
end

def cinemas
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


def fetch_sessions(id, date)
  url = "http://www.unitedcinemas.com.au/session_data.php?date=#{date}&l=#{id}&sort=title"
  page = get(url)

  sessions = extract_sessions(page)
  sessions.each do |session|
    session['datetime'] = DateTime.parse(date + ' ' + session.delete('time'))
  end
end

def dates
  (Date.today..Date.today + 1).to_a.map(&:to_s)
end

def primary_key
  %w(link)
end

def main
  sessions = []

  cinemas.each do |cinema|
    dates.each do |date|
      puts "### Fetching sessions for #{cinema['name']} on #{date}"
      sessions += fetch_sessions(cinema['id'], date)
    end
  end

  puts "### Scraped #{sessions.size} sessions across #{cinemas.size} cinemas"
  puts "### There are #{existing_record_ids.size} existing sessions"
  new_sessions = sessions.select {|r| !existing_record_ids.include?(r['link'])}
  puts "### There are #{new_sessions.size} new sessions"

  # Serialise
  ScraperWiki.save_sqlite(primary_key, new_sessions)

  puts 'Done'
end

main()
