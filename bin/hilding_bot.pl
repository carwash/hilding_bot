#!/usr/bin/env perl

use strict;
use warnings;
use utf8;
use 5.016;
use autodie qw(:file);
use open qw(:utf8 :std);

#use Encode; # On some platforms you may need to explicitly decode strings from K-samsök/SOCH; see parse_rdf() below.
use LWP::UserAgent::Determined;
use List::MoreUtils qw(any samples);
use MIME::Base64;
use RDF::Trine;
use Sort::Key::Natural qw(natsort);
use Try::Tiny;
use Twitter::API;
use YAML::XS qw(DumpFile LoadFile);

# hilding_bot
# Tweet random photos from the Hilding Mickelsson collection at Hälsinglands Museum

# Get an authorised Twitter client object:
my $client = oauth();

# Subtract the set of URIs we've already used from the cache of all available URIs:
my (@uricache, %used);
if (-e -f -s -r -w './uri-cache.yml') {
	@uricache = @{LoadFile('./uri-cache.yml')} or die "Failed to read URI cache file: $!\n";
}
else {
	die "Could not find/read URI cache file: $!\n";
}
if (-e -f -s -r -w './used-uris.yml') {
	%used     = map {$_ => 1} @{LoadFile('./used-uris.yml')} or die "Failed to read used URIs file: $!\n";
}
else {
	die "Could not find/read used URIs file: $!\n";
}
my @pool     = grep {!(exists $used{$_})} @uricache;

# If we've cycled through all available images, reset the cache and start repeating:
unless (@pool) {
	@pool = @uricache;
	%used = ();
}

my ($uri, $success, $iterations) = (undef, 0, 0);
# Main loop; if any stage fails, try again, up to ten times:
until ($success || ++$iterations > 10) {
	# Pick a random URI from the pool of available photos:
	($uri) = samples 1, @pool;

	# Fetch the data:
	($success, my $rdf) = get_rdf($uri);
	next unless $success;

	# Parse it and clean it up:
	($success, my $fields) = parse_rdf($uri, $rdf);
	next unless $success;
	$fields = unquote($fields);

	# Check we have the required image fields:
	unless (exists $fields->{mediaLicense} &&
	        (exists $fields->{highresSource} ||
	         exists $fields->{lowresSource})) {
		$success = 0;
		next;
	}

	# Compose the text:
	($success, my $text) = construct_text($fields);
	next unless $success;

	# Fetch the image:
	($success, my $image, my $bytes) = get_image($fields);
	next unless $success;

	# Upload the image:
	($success, my $media_id) = upload_image($client, $image, $bytes, $fields->{mediaType}[0]);
	next unless $success;

	# Post tweet:
	$success = tweet($client, $text, $media_id);
} # Fin

# Update the list of used URIs:
$used{$uri} = 1;
DumpFile('./used-uris.yml', [natsort keys %used]) or die "Failed to write used-uris file: $!\n";

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


# Dereference the URI, get the RDF:
sub get_rdf {
	my $uri = shift();
	my $ua = soch_user_agent('hilding_bot');

	my $req = HTTP::Request->new(GET => $uri);
	$req->accept_decodable;
	my $response = $ua->request($req);
	unless ($response->is_success) {
		return(0, undef);
	}
	my $rdf = $response->decoded_content;
	return(1, $rdf);
}


# Parse the RDF, and extract the details we want:
sub parse_rdf {
	my ($uri, $rdf) = @_;

	# Define namespaces:
	my $prefixes = RDF::Trine::NamespaceMap->new({
	                                              ctype => 'http://kulturarvsdata.se/resurser/ContextType#',
	                                              rdf   => 'http://www.w3.org/1999/02/22-rdf-syntax-ns#',
	                                              soch  => 'http://kulturarvsdata.se/ksamsok#',
	                                             });

	# Create a temporary triplestore in memory:
	my $store = RDF::Trine::Store->new('Memory');
	my $model = RDF::Trine::Model->new($store);
	my $xml_parser = RDF::Trine::Parser->new('rdfxml');
	
	my $parsed = try {
		$xml_parser->parse_into_model($uri, $rdf, $model);
		1;
	}
	catch {
		warn 'Failed to parse RDF: ', $_, "\n";
		return undef;
	};
	unless ($parsed) {
		return (0, {});
	}
	
	my %fields = (
	              uri => [$uri],
	             );
	my $base = RDF::Trine::Node::Resource->new($uri);

	# Use RDF::Trine's basic query API to find and extract the fields we need, where they exist.
	# For anything more complex than this, the SPARQL interface is probably preferable.

	# Simple fields:
	for my $field (qw(itemLabel itemKeyWord)) {
		for my $value ($model->objects($base, $prefixes->soch($field))) {
			push @{$fields{$field}}, $value->as_string();
			#push @{$fields{$field}}, Encode::decode("utf8", $value->as_string()); # On some platforms you may need to explicitly decode strings from K-samsök/SOCH.
		}
	}

	# Blank nodes:
	for my $context ($model->subjects($prefixes->soch('contextType'), $prefixes->ctype('produce'))) {
		for my $field (qw(fromTime toTime)) {
			for my $value ($model->objects($context, $prefixes->soch($field))) {
				push @{$fields{$field}}, $value->as_string();
				#push @{$fields{$field}}, Encode::decode('utf8', $value->as_string()); # On some platforms you may need to explicitly decode strings from K-samsök/SOCH.
			}
		}
	}
	for my $context ($model->subjects($prefixes->rdf('type'), $prefixes->soch('Image'))) {
		for my $field (qw(mediaLicenseUrl highresSource lowresSource thumbnailSource mediaType)) {
			for my $value ($model->objects($context, $prefixes->soch($field))) {
				push @{$fields{$field}}, $value->as_string();
				#push @{$fields{$field}}, Encode::decode('utf8', $value->as_string()); # On some platforms you may need to explicitly decode strings from K-samsök/SOCH.
			}
		}
	}
	for my $context ($model->subjects($prefixes->rdf('type'), $prefixes->soch('ItemDescription'))) {
		next unless any {$_->as_string() eq $context->as_string()} ($model->subjects($prefixes->soch('type'), RDF::Trine::Node::Literal->new('Motiv')));
		for my $value ($model->objects($context, $prefixes->soch('desc'))) {
			push @{$fields{'ItemDescription'}}, $value->as_string();
			#push @{$fields{'ItemDescription'}}, Encode::decode('utf8', $value->as_string()); # On some platforms you may need to explicitly decode strings from K-samsök/SOCH.
		}
	}
	for my $context ($model->subjects($prefixes->rdf('type'), $prefixes->soch('ItemName'))) {
		next unless any {$_->as_string() eq $context->as_string()} ($model->subjects($prefixes->soch('type'), RDF::Trine::Node::Literal->new('Motiv')));
		for my $value ($model->objects($context, $prefixes->soch('name'))) {
			push @{$fields{'ItemName'}}, $value->as_string();
			#push @{$fields{'ItemName'}}, Encode::decode('utf8', $value->as_string()); # On some platforms you may need to explicitly decode strings from K-samsök/SOCH.
		}
	}
	return (1, \%fields);
}


# Unquote and generally clean up fields:
sub unquote {
	my %fields = %{shift()};

	for my $field (keys %fields) {
		for (@{$fields{$field}}) {
			s/^[<"]//;
			s/[>"]$//;
			# The descriptions of Hilding's photos sometimes include this at the end; we don't need it:
			s/ \(Avbildad(?:,| -) (?:ort|namn)\)$//gi;
			# A default date of 1st January stands in for a whole year; in such cases we can strip it to just the year (with a small risk of false-positives!):
			if ($field =~ /Time$/) {
				s/-01-01$//;
			}
			# Get the proper MIME type from the URI:
			elsif ($field eq 'mediaType') {
				s!^http://kulturarvsdata.se/resurser/MediaType#!!;
			}
			# Convert the license URI to its initial text:
			elsif ($field eq 'mediaLicenseUrl') {
				push @{$fields{'mediaLicense'}}, licenses($_, 'name');
			}
		}
	}
	return \%fields;
}


# Build the tweet text:
sub construct_text {
	my %fields = %{shift()};
	my %text = (main => '');

	# Prefer whichever is longest of these three (subject to caveats – see below):
	for (qw(ItemDescription ItemName itemLabel)) {
		if (exists $fields{$_} &&
		    defined $fields{$_}[0]) {
		    # Sometimes the "descriptions" of Hilding's photos are just a list of place-/region-names. For our purposes these are better of in their own field:
		    if ($fields{$_}[0] =~ /^(?:Sverige|USA|Kanada|Norge|Danmark|Finland)/) {
		        $text{location} = join('', "\n", 'Avbildad plats: ', $fields{$_}[0]);
		    }
		    # Otherwise treat this as the "main" text:
		    elsif ($fields{$_}[0] !~ /^(?:Sverige|USA|Kanada|Norge|Danmark|Finland)/ &&
		        length($fields{$_}[0]) > length($text{main})) {
		        $text{main} = $fields{$_}[0];
		    }
		}
	}
	# Sort and concatenate keyword lists:
	if (exists $fields{itemKeyWord} && @{$fields{itemKeyWord}}) {
		$text{keywords} = join('', "\n", 'Nyckelord: ', join(', ', natsort @{$fields{itemKeyWord}}));
	}
	if (exists $fields{fromTime}) {
		$text{date} = join('', "\n", $fields{fromTime}[0]);
	}
	# License and links:
	$text{license} = join('', "\n", $fields{mediaLicense}[0], ' Hilding Mickelsson'); 
	$text{kringla} = "\nKringla: ";
	$text{uri} = "\nURI: ";

	# We have all our fields (almost); now check for length. How many characters do we have to play with after boilerplate, if any?
	# NB: have to add c.25 characters to be safe for shortened links to Kringla + URI:
	my $mainmax = 240 - (length(join('', @text{qw(license kringla uri)}, exists $text{date} ? $text{date} : '')) + (25*2));

	# Build the text:
	# Links:
	$text{kringla} .= $fields{uri}[0] =~ s!^http://kulturarvsdata\.se/!http://www.kringla.nu/kringla/objekt?referens=!r;
	$text{uri} .= $fields{uri}[0];

	# If the main text is already too long, elide it at the last appropriate word boundary. That's all we have room for – no other metadata fields.
	if (length($text{main}) > $mainmax) {
		my $diff = $mainmax - 1; # +1 for the ellipsis we're going to add.
		$text{main} = (sprintf "%.${diff}s", $text{main}) =~ s/\s\S*$//r;
		$text{final} = join('', $text{main}, '…', exists $text{date} ? $text{date} : '', @text{qw(license kringla uri)});
	}
	# Otherwise, we might have space to include some more information on location and keywords:
	else {
		$text{final} = join('', $text{main}, exists $text{date} ? $text{date} : '');
		my $diff = $mainmax - length($text{main});
		for my $field (qw(location keywords)) {
			if (exists $text{$field} && $text{$field}) {
				if (length($text{$field}) <= $diff) {
					$text{final} .= $text{$field};
					$diff = $diff - length($text{$field});
				}
				elsif (length($text{$field} =~ s/^(\n(?:Avbildad plats|Nyckelord): \S+).*/$1/r) <= $diff) {
					$text{final} .= (sprintf "%.${diff}s", $text{$field}) =~ s/,?\s\S+$//r;
					$diff = $diff - length((sprintf "%.${diff}s", $text{$field}) =~ s/,?\s\S+$//r);
				}
			}
		}
		$text{final} .= join('', @text{qw(license kringla uri)});
	}
	# Remove any initial line breaks that might have crept in:
	$text{final} =~ s/^\n//;
	# Final length check (accounting for shortened URLs):
	return (((length($text{final} =~ s/ http\S+//gr) + (25*2)) <= 240), $text{final});
	}


# Dereference the image URL:
sub get_image {
	my %fields = %{shift()};
	my $ua = soch_user_agent('hilding_bot');
	my $source = exists $fields{highresSource} ? 'highresSource' : 'lowresSource';
	my $url = $fields{$source}[0];

	my $req = HTTP::Request->new(GET => $url, ['Accept' => $fields{mediaType}[0]]);
	$req->accept_decodable;
	my $response = $ua->request($req);
	unless ($response->is_success) {
		return(0, undef, undef);
	}
	my $bytes = $response->header('Content-Length') || do {use bytes; length($response->content)};
	# Check that the image size is under Twitter's limit of 5Mb:
	return(($bytes < 5242880), $response->content, $bytes);
}


# Upload the image to Twitter and return a media_id:
sub upload_image {
	my ($client, $image, $bytes, $mime) = @_;
	my $req;
	# INITiate image upload, and get a media_id:
	my $success = try {
		$req = $client->upload_media({
		                              command        => 'INIT',
		                              total_bytes    => $bytes,
		                              media_type     => $mime,
		                              media_category => 'TweetImage',
		                             });
		1;
	}
	catch {
		warn 'INIT failed. Twitter says: ', $_->twitter_error_text, "\n";
		return undef;
	};
	unless ($success) {
		return (0, undef);
	}
	my $media_id = $req->{media_id};

	# APPEND the image itself:
	# (NB: we upload the image as a single chunk; no attempt is made to chop up the image and upload accross multiple APPENDs)
	$success = try {
		$client->upload_media({
		                       command       => 'APPEND',
		                       media_id      => $media_id,
		                       #media         => $image, # Twitter prefers raw bytes, but base64 seems to be less error-prone.
		                       media_data     => encode_base64($image),
		                       segment_index => 0,
		                      });
		1;
	}
	catch {
		warn 'APPEND failed. Twitter says: ', $_->twitter_error_text, "\n";
		return undef;
	};
	unless ($success) {
		return (0, undef);
	}

	# FINALIZE the upload:
	$success = try {
		$req = $client->upload_media({
		                              command  => 'FINALIZE',
		                              media_id => $media_id,
		                             });
		1;
	}
	catch {
		warn 'FINALIZE failed. Twitter says: ', $_->twitter_error_text, "\n";
		return undef;
	};
	unless ($success) {
		return (0, undef);
	}
	$media_id = $req->{media_id};

	# If the image uploaded okay but is still being processed, we need to wait, and periodically check status:
	if (exists $req->{processing_info}) {
		sleep 6;
		my $wait = 1;
		while ($wait) {
			my $success = try {
				$req = $client->upload_media({
				                              command  => 'STATUS',
				                              media_id => $media_id,
				                             });
				1;
			}
			catch {
				warn 'STATUS failed. Twitter says: ', $_->twitter_error_text, "\n";
				return undef;
			};
			unless ($success) {
				return (0, undef);
			}
			if ($req->{processing_info}{state} eq 'succeeded') {
				$wait = 0;
			}
			elsif ($req->{processing_info}{state} eq 'pending' ||
			       $req->{processing_info}{state} eq 'in_progress') {
				sleep ($req->{processing_info}{check_after_secs} + 1);
			}
			else {
				return (0, undef);
			}
		}
	}
	return (1, $media_id);
}


# Post the text to Twitter:
sub tweet {
	my ($client, $tweet, $media_id) = @_;
	# Post:
	my $success = try {
		$client->update({
		                 status    => $tweet,
		                 media_ids => [$media_id],
		                });
		1;
	}
	catch {
		warn 'Tweet failed. Twitter says: ', $_->twitter_error_text, "\n";
		return undef;
	};
	return $success;
}


# Get an authorised Twitter client object:
sub oauth {
	my ($client, %oauth);
	if (-e -f -s -r -w './oauth.yml') {
		%oauth = %{LoadFile('./oauth.yml')} or die "Failed to read Twitter OAuth file: $!\n";
	}
	else {
		die "Could not find/read Twitter OAuth file: $!\n";
	}
	if (exists $oauth{consumer_key} && defined $oauth{consumer_key} &&
	    exists $oauth{consumer_secret} && defined $oauth{consumer_secret}) {
		$client = Twitter::API->new_with_traits(
		                                        traits          => [qw(ApiMethods RetryOnError)],
		                                        consumer_key    => $oauth{consumer_key},
		                                        consumer_secret => $oauth{consumer_secret},
		                                       );
	}
	else {
		die "Could not find Twitter OAuth consumer key!\n";
	}

	if (exists $oauth{access_token} && defined $oauth{access_token} &&
	    exists $oauth{access_token_secret} && defined $oauth{access_token_secret}) {
		$client->access_token($oauth{access_token});
		$client->access_token_secret($oauth{access_token_secret});
	}
	else { # The client is not yet authorized; do it now:
		# Get a request token and secret:
		my ($req, $auth_url);
		try {
			$req = $client->oauth_request_token;
		}
		catch {
			die "Error acquiring Twitter OAuth access token!\n";
		};

		# Generate an authorization URL from the request token:
		try {
			$auth_url = $client->oauth_authorization_url({
			                                              oauth_token => $req->{oauth_token},
			                                             });
		}
		catch {
			die "Error acquiring Twitter OAuth authorization URL!\n";
		};
		say join(' ', 'Authorise this app at', $auth_url, 'and enter the PIN#:');
		my $pin = <STDIN>; # Wait for input
		chomp $pin;
		@oauth{qw(access_token access_token_secret user_id screen_name)} = @{$client->oauth_access_token(
			                           token        => $req->{oauth_token},
			                           token_secret => $req->{oauth_token_secret},
			                           verifier     => $pin,
			                          )}{qw(oauth_token oauth_token_secret user_id screen_name)};
		$client->access_token($oauth{access_token});
		$client->access_token_secret($oauth{access_token_secret});
		say join(' ', 'Authorised user', $oauth{screen_name}, '.');
		DumpFile('./oauth.yml', \%oauth) or die "Failed to write Twitter OAuth file: $!\n";
	} # Everything's ready
	return $client;
}


# What do all the license URIs mean?
sub licenses {
	my ($license, $name) = @_;
	my %licenses = (
	                'http://rightsstatements.org/vocab/InC/1.0/' => {
	                                                                 'name'     => '©',
	                                                                 'longname' => 'In Copyright',
	                                                                },
	                'http://creativecommons.org/licenses/by/2.5/' => {
	                                                                  'name'     => 'CC BY',
	                                                                  'longname' => 'Creative Commons Attribution 2.5 Unported',
	                                                                 },
	                'http://creativecommons.org/licenses/by/2.5/se/' => {
	                                                                     'name'     => 'CC BY',
	                                                                     'longname' => 'Creative Commons Erkännande 2.5 Sverige',
	                                                                    },
	                'http://creativecommons.org/licenses/by/3.0/' => {
	                                                                  'name'     => 'CC BY',
	                                                                  'longname' => 'Creative Commons Attribution 3.0 Unported',
	                                                                 },
	                'http://creativecommons.org/licenses/by/4.0/' => {
	                                                                  'name'     => 'CC BY',
	                                                                  'longname' => 'Creative Commons Attribution 4.0',
	                                                                 },
	                'http://creativecommons.org/licenses/by-nc/2.5/' => {
	                                                                     'name'     => 'CC BY-NC',
	                                                                     'longname' => 'Creative Commons Attribution-NonCommercial 2.5 Unported',
	                                                                    },
	                'http://creativecommons.org/licenses/by-nc/2.5/se/' => {
	                                                                        'name'     => 'CC BY-NC',
	                                                                        'longname' => 'Erkännande-Ickekommersiell 2.5 Sverige',
	                                                                       },
	                'http://creativecommons.org/licenses/by-nc/3.0/' => {
	                                                                     'name'     => 'CC BY-NC',
	                                                                     'longname' => 'Creative Commons Attribution-NonCommercial 3.0 Unported',
	                                                                    },
	                'http://creativecommons.org/licenses/by-nc/4.0/' => {
	                                                                     'name'     => 'CC BY-NC',
	                                                                     'longname' => 'Creative Commons Attribution-NonCommercial 4.0',
	                                                                    },
	                'http://creativecommons.org/licenses/by-nc-nd/2.5/' => {
	                                                                        'name'     => 'CC BY-NC-ND',
	                                                                        'longname' => 'Creative Commons Attribution-NonCommercial-NoDerivs 2.5 Unported',
	                                                                       },
	                'http://creativecommons.org/licenses/by-nc-nd/2.5/se/' => {
	                                                                           'name'     => 'CC BY-NC-ND',
	                                                                           'longname' => 'Erkännande-Ickekommersiell-IngaBearbetningar 2.5 Sverige',
	                                                                          },
	                'http://creativecommons.org/licenses/by-nc-nd/3.0/' => {
	                                                                        'name'     => 'CC BY-NC-ND',
	                                                                        'longname' => 'Creative Commons Attribution-NonCommercial-NoDerivs 3.0 Unported',
	                                                                       },
	                'http://creativecommons.org/licenses/by-nc-nd/4.0/' => {
	                                                                        'name'     => 'CC BY-NC-ND',
	                                                                        'longname' => 'Creative Commons Attribution-NonCommercial-NoDerivs 4.0',
	                                                                       },
	                'http://creativecommons.org/licenses/by-nc-sa/2.5/' => {
	                                                                        'name'     => 'CC BY-NC-SA',
	                                                                        'longname' => 'Creative Commons Attribution-NonCommercial-ShareAlike 2.5 Unported',
	                                                                       },
	                'http://creativecommons.org/licenses/by-nc-sa/2.5/se/' => {
	                                                                           'name'     => 'CC BY-NC-SA',
	                                                                           'longname' => 'Erkännande-IckeKommersiell-DelaLika 2.5 Sverige',
	                                                                          },
	                'http://creativecommons.org/licenses/by-nc-sa/3.0/' => {
	                                                                        'name'     => 'CC BY-NC-SA',
	                                                                        'longname' => 'Creative Commons Attribution-NonCommercial-ShareAlike 3.0 Unported',
	                                                                       },
	                'http://creativecommons.org/licenses/by-nc-sa/4.0/' => {
	                                                                        'name'     => 'CC BY-NC-SA',
	                                                                        'longname' => 'Creative Commons Attribution-NonCommercial-ShareAlike 4.0',
	                                                                       },
	                'http://creativecommons.org/licenses/by-sa/2.5/' => {
	                                                                     'name'     => 'CC BY-SA',
	                                                                     'longname' => 'Creative Commons Attribution-ShareAlike 2.5 Unported',
	                                                                    },
	                'http://creativecommons.org/licenses/by-sa/2.5/se/' => {
	                                                                        'name'     => 'CC BY-SA',
	                                                                        'longname' => 'Erkännande-DelaLika 2.5 Sverige',
	                                                                       },
	                'http://creativecommons.org/licenses/by-sa/3.0/' => {
	                                                                     'name'     => 'CC BY-SA',
	                                                                     'longname' => 'Creative Commons Attribution-ShareAlike 3.0 Unported',
	                                                                    },
	                'http://creativecommons.org/licenses/by-sa/4.0/' => {
	                                                                     'name'     => 'CC BY-SA',
	                                                                     'longname' => 'Creative Commons Attribution-ShareAlike 4.0',
	                                                                    },
	                'http://creativecommons.org/publicdomain/zero/1.0/' => {
	                                                                        'name'     => 'CC0',
	                                                                        'longname' => 'Creative Commons Zero',
	                                                                       },
	                'http://creativecommons.org/publicdomain/mark/1.0/' => {
	                                                                        'name'     => 'PD',
	                                                                        'longname' => 'Public Domain',
	                                                                       },

	                # Wrong, but for compatibility:
	                'http://kulturarvsdata.se/resurser/License#by' => {
	                                                                   'name'     => 'CC BY',
	                                                                   'longname' => 'Creative Commons Erkännande 2.5 Sverige',
	                                                                  },
	                'http://creativecommons.org/licenses/by-nc-nd/2.5/se' => {
	                                                                          'name'     => 'CC BY-NC-ND',
	                                                                          'longname' => 'Creative Commons Erkännande-Ickekommersiell-Inga-Bearbetningar 2.5 Sverige',
	                                                                         },
	                'http://creativecommons.org/licenses/mark/1.0/' => {
	                                                                    'name'     => 'PD',
	                                                                    'longname' => 'Public Domain',
	                                                                   },
	                'http://kulturarvsdata.se/resurser/License#pdmark' => {
	                                                                       'name'     => 'PD',
	                                                                       'longname' => 'Public Domain',
	                                                                      },
	               );
	return $licenses{$license}{$name};
}
