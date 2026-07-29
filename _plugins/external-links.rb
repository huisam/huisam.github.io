require "nokogiri"

Jekyll::Hooks.register [:pages, :posts], :post_render do |doc|
  next unless doc.output_ext == ".html"

  parsed = Nokogiri::HTML.fragment(doc.output)
  site_url = doc.site.config["url"] || ""

  parsed.css("a[href]").each do |link|
    href = link["href"]
    next if href.nil? || href.empty?
    next if href.start_with?("/", "#", "mailto:", "tel:")
    next if !site_url.empty? && href.start_with?(site_url)

    link["target"] = "_blank"
    link["rel"] = "noopener noreferrer"
  end

  doc.output = parsed.to_html
end
