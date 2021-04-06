#!/usr/bin/env perl

use strict;
use warnings;
use utf8;
use 5.016;
use autodie qw(:file);
use open qw(:utf8 :std);

use LWP::UserAgent::Determined;
use MCE;
use POSIX qw(ceil);
use Sort::Key::Natural qw(natsort);
use XML::XPath;
use YAML::XS qw(DumpFile);

# Enforce proper garbage collection on XML::XPath:
$XML::XPath::SafeMode = 1;

# hilding_cache
# Periodically run a search to list the URIs of all Hilding Mickelsson's photos (with licenses) for use by hilding_bot

my $ua = soch_user_agent('hilding_bot');
my $cql = 'itemType="foto" AND serviceOrganization="s-hm" AND create_name="Mickelsson, Hilding" AND thumbnailExists=j AND mediaLicense="*"';

DumpFile('./uri-cache.yml', list_uris($ua, $cql)) or die "Failed to write uri-cache file: $!\n";

# Exeunt omnes, laughing.

################################################################################

# Create a user-agent object:
sub soch_user_agent {
	my $ua = LWP::UserAgent::Determined->new();
	$ua->agent(shift());
	$ua->default_header('Accept' => 'application/rdf+xml, application/xml, text/xml');
	$ua->timing ('1,5,10,20,60,240');
	return($ua);
}


# Return a list of all matching URIs:
sub list_uris {
	my ($ua, $cql) = @_;
	my @uris;

	# Search results are paged; how many pages will we need to request?
	my $pages = ceil(get_hits($ua, $cql)/500);

	# Fetch all results pages in parallel, and append their object URIs to the list:
	my $mce = MCE->new(
	                   max_workers => 'auto',
	                   chunk_size  => ceil($pages/8),
	                   gather      => sub {
		                   push @uris, @_;
	                   },
	                   user_func   => sub {
		                   my ($mce, $chunk_ref, $chunk_id) = @_;
		                   for my $page (@{$chunk_ref}) {
			                   MCE->gather(@{get_uris($ua, $page, $cql)});
		                   }
	                   },
	                  );

	$mce->process([1..$pages]);
	$mce->shutdown;
	return [natsort @uris];
}


# Query K-samsök/SOCH for the number of matching objects:
sub get_hits {
	my ($ua, $cql) = @_;
	my $req = HTTP::Request->new(GET => join('', 'https://kulturarvsdata.se/ksamsok/api?version=1.1', '&method=search', '&hitsPerPage=', 1, '&startRecord=', 1, '&sort=addedToIndexDate', '&query=', $cql));
	$req->accept_decodable;
	my $response = $ua->request($req);
	unless ($response->is_success) {
		warn 'Error fetching number of hits: ', $response->status_line, "\n";
		return 0;
	}
	my $xp = XML::XPath->new($response->decoded_content);
	my $nodes = $xp->find('/result/totalHits/text()');
	my ($hits) = map {XML::XPath::XMLParser::as_string($_)} $nodes->get_nodelist();
	$xp->cleanup();
	return $hits;
}


# Query K-samsök/SOCH for a list of URIs for all matching objects from a particular page of results:
sub get_uris {
	my ($ua, $page, $cql) = @_;
	my %uris;
	my $start_record = (($page-1)*500)+1;
	my $req = HTTP::Request->new(GET => join('', 'https://kulturarvsdata.se/ksamsok/api?version=1.1', '&method=search', '&hitsPerPage=', 500, '&startRecord=', $start_record, '&sort=addedToIndexDate', '&query=', $cql));
	$req->accept_decodable;
	my $response = $ua->request($req);
	unless ($response->is_success) {
		warn 'Error fetching URI search results: ', $response->status_line, "\n";
		return [];
	}
	my $xp = XML::XPath->new($response->decoded_content);
	my $nodes = $xp->find('/result/records/record/rdf:RDF/rdf:Description/@rdf:about | /result/records/record/rdf:RDF/Entity/@rdf:about');
	map {$uris{$_->getNodeValue()} = 1} $nodes->get_nodelist();
	$xp->cleanup();
	return [keys %uris];
}
