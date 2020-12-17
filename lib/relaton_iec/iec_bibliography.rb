# frozen_string_literal: true

# require 'isobib/iso_bibliographic_item'
require "relaton_iec/scrapper"
require "relaton_iec/hit_collection"
require "date"

module RelatonIec
  # Class methods for search ISO standards.
  class IecBibliography
    class << self
      ##
      # Search for standards entries. To seach packaged document it needs to
      # pass part parametr.
      #
      # @example Search for packaged standard
      #   RelatonIec::IecBibliography.search 'IEC 60050-311', nil, '311'
      #
      # @param text [String]
      # @param year [String, nil]
      # @param part [String, nil] search for packaged stndard if not nil
      # @return [RelatonIec::HitCollection]
      def search(text, year = nil, part = nil)
        HitCollection.new text, year&.strip, part
      rescue SocketError, OpenURI::HTTPError, OpenSSL::SSL::SSLError
        raise RelatonBib::RequestError, "Could not access http://www.iec.ch"
      end

      # @param code [String] the ISO standard Code to look up (e..g "ISO 9000")
      # @param year [String] the year the standard was published (optional)
      # @param opts [Hash] options; restricted to :all_parts if all-parts
      #   reference is required
      # @return [String] Relaton XML serialisation of reference
      def get(code, year = nil, opts = {}) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/MethodLength,Metrics/PerceivedComplexity
        if year.nil?
          /^(?<code1>[^:]+):(?<year1>[^:]+)/ =~ code
          unless code1.nil?
            code = code1
            year = year1
          end
        end

        return iev if code.casecmp("IEV").zero?

        opts[:all_parts] ||= !(code =~ / \(all parts\)/).nil?
        code = code.sub(/ \(all parts\)/, "")
        ret = iecbib_get1(code, year, opts)
        return nil if ret.nil?

        ret = ret.to_most_recent_reference unless year || opts[:keep_year]
        ret = ret.to_all_parts if opts[:all_parts]
        ret
      end

      private

      def fetch_ref_err(code, year, missed_years) # rubocop:disable Metrics/MethodLength
        id = year ? "#{code}:#{year}" : code
        warn "[relaton-iec] WARNING: no match found online for #{id}. "\
          "The code must be exactly like it is on the standards website."
        unless missed_years.empty?
          warn "[relaton-iec] (There was no match for #{year}, though there "\
            "were matches found for #{missed_years.join(', ')}.)"
        end
        if /\d-\d/.match? code
          warn "[relaton-iec] The provided document part may not exist, or "\
            "the document may no longer be published in parts."
        else
          warn "[relaton-iec] If you wanted to cite all document parts for "\
            "the reference, use \"#{code} (all parts)\".\nIf the document is "\
            "not a standard, use its document type abbreviation (TS, TR, PAS, "\
            "Guide)."
        end
        nil
      end

      # @param hits [Array<RelatonIec::Hit>]
      # @param threads [Integer]
      # @return [Array<RelatonIec::Hit>]
      def fetch_pages(hits, threads)
        workers = RelatonBib::WorkersPool.new threads
        workers.worker { |w| { i: w[:i], hit: w[:hit].fetch } }
        hits.each_with_index { |hit, i| workers << { i: i, hit: hit } }
        workers.end
        workers.result.sort_by { |a| a[:i] }.map { |x| x[:hit] }
      end

      def isobib_search_filter(reference, year, opts) # rubocop:disable Metrics/AbcSize,Metrics/MethodLength,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
        %r{
          ^(?<code>(?:ISO|IEC)[^\d]*\s[\d-]+\w?)
          (:(?<year1>\d{4}))?
          (?<bundle>\+[^\s\/]+)?
          (\/(?<corr>AMD\s\d+))?
        }x =~ reference.upcase
        year ||= year1
        corr&.sub! " ", ""
        warn "[relaton-iec] (\"#{reference}\") fetching..."
        result = search(code, year)
        if result.empty? && /(?<=-)(?<part>\d+)/ =~ code
          # try to search packaged standard
          result = search code, year, part
          ref = code.sub /(?<=-\d)\d+/, ""
        else ref = code
        end
        result.select do |i|
          %r{
            ^(?<code2>(?:ISO|IEC)[^\d]*\s\d+(-\w+)?)
            (:(?<year2>\d{4}))?
            (?<bundle2>\+[^\s\/]+)?
            (\/(?<corr2>AMD\d+))?
          }x =~ i.hit[:code]
          code2.sub! /(?<=-\d)\w*/, "" if part
          code2.sub! /-\d+\w*/, "" if opts[:all_parts]
          ref == code2 && (year.nil? || year == year2) && bundle == bundle2 &&
            corr == corr2
        end
      end

      def iev(code = "IEC 60050")
        RelatonIsoBib::XMLParser.from_xml(<<~"XML")
          <bibitem>
            <fetched>#{Date.today}</fetched>
            <title format="text/plain" language="en" script="Latn">International Electrotechnical Vocabulary</title>
            <link type="src">http://www.electropedia.org</link>
            <docidentifier>#{code}:2011</docidentifier>
            <date type="published"><on>2011</on></date>
            <contributor>
              <role type="publisher"/>
              <organization>
                <name>International Electrotechnical Commission</name>
                <abbreviation>IEC</abbreviation>
                <uri>www.iec.ch</uri>
              </organization>
            </contributor>
            <language>en</language> <language>fr</language>
            <script>Latn</script>
            <status> <stage>60</stage> </status>
            <copyright>
              <from>2018</from>
              <owner>
                <organization>
                <name>International Electrotechnical Commission</name>
                <abbreviation>IEC</abbreviation>
                <uri>www.iec.ch</uri>
                </organization>
              </owner>
            </copyright>
          </bibitem>
        XML
      end

      # Sort through the results from Isobib, fetching them three at a time,
      # and return the first result that matches the code,
      # matches the year (if provided), and which
      # has a title (amendments do not).
      # Only expects the first page of results to be populated.
      # Does not match corrigenda etc (e.g. ISO 3166-1:2006/Cor 1:2007)
      # If no match, returns any years which caused mismatch, for error
      # reporting
      def isobib_results_filter(result, year) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/MethodLength
        missed_years = []
        result.each_slice(3) do |s| # ISO website only allows 3 connections
          fetch_pages(s, 3).each_with_index do |r, _i|
            return { ret: r } if !year

            r.date.select { |d| d.type == "published" }.each do |d|
              return { ret: r } if year.to_i == d.on(:year)

              missed_years << d.on(:year)
            end
          end
        end
        { years: missed_years }
      end

      def iecbib_get1(code, year, opts)
        return iev if code.casecmp("IEV").zero?

        result = isobib_search_filter(code, year, opts) || return
        ret = isobib_results_filter(result, year)
        if ret[:ret]
          warn "[relaton-iec] (\"#{code}\") found "\
          "#{ret[:ret].docidentifier.first.id}"
          ret[:ret]
        else
          fetch_ref_err(code, year, ret[:years])
        end
      end
    end
  end
end
