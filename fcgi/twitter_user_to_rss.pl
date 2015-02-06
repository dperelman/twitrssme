#!/usr/bin/perl
use strict;
use warnings;
use utf8;
use 5.10.0;
use Data::Dumper;
use Readonly;
use HTML::TreeBuilder::XPath;
use HTML::TreeBuilder::LibXML;
use HTML::Entities;
use List::Flatten;
use LWP::ConnCache; 
use LWP::UserAgent;
use LWP::Protocol::Net::Curl; #net thing to try for performance
use CGI::Fast;
use Encode;
use POSIX qw(strftime);

binmode STDOUT, 'utf8';
binmode STDIN, 'utf8';

HTML::TreeBuilder::LibXML->replace_original();

Readonly my $BASEURL => 'https://twitter.com';
my $browser = LWP::UserAgent->new;
$browser->conn_cache(LWP::ConnCache->new(5));
$browser->timeout(2);


while (my $q = CGI::Fast->new) {
#    err("Over capacity.  Try running your own instance - code on github.",404);
#    next;
        my @ps = $q->param; 
        my $bad_param=0;
        for(@ps) {
          unless ($_=~/^(fetch|replies|user)$/) {
            err("Bad parameters. Naughty.",405); 
            $bad_param++;
            last;
          }
        } 
        next if $bad_param;

	my $user = $q->param('user') || 'ciderpunx';

	$user = lc $user;
        if($user =~ '^#') {
		err("That was an hashtag, TwitRSS.me only supports users!",404); 
                next;
	}
	$user=~s/(@|\s)//g;
	$user=~s/%40//g;

	my $max_age=1800;

	my $replies = $q->param('replies') || 0;

	my $url = "$BASEURL/$user";
	$url .= "/with_replies" if $replies;

	my $response = $browser->get($url);
	unless ($response->is_success) {
		err('Can&#8217;t screenscrape Twitter',404);
		next;
	}
	my $content = $response->content;

	my @items;

	my $tree= HTML::TreeBuilder::XPath->new;
	$tree->parse($content);
        my $feedavatar = $tree->findvalue('//img' . class_contains("ProfileAvatar-image") . "/\@src"); 
        # Get capitalization from Twitter page
        my $normalizedName = $tree->findvalue('//a' . class_contains("ProfileHeaderCard-screennameLink") . "/\@href"); 
        $normalizedName =~ s{^/}{};
        $user = $normalizedName;
  my $tweets = $tree->findnodes( '//div' . class_contains('js-stream-item')); # new version 2014ish
  if ($tweets) {
    for my $li (@$tweets) {    
      my $tweet = $li->findnodes('./div' 
                                  . class_contains("js-tweet") 
                                )->[0]
      ;
      next unless $tweet;
      my $header = $tweet->findnodes('./div' 
                                     . class_contains("ProfileTweet-header") 
                                     . "/div" 
                                     . class_contains("ProfileTweet-authorDetails"))->[0];
      my $body   = $tweet->findvalue('./div' 
                                     . class_contains("ProfileTweet-contents") 
                                     . '/p' 
                                     . class_contains("js-tweet-text"));
      $body = HTML::Entities::encode_numeric($body);
      my $avatar = $header->findvalue('./a/img' . class_contains("ProfileTweet-avatar") . "/\@src"); 
      my $mediadivs = $tweet->findnodes('.//div' . class_contains('js-media-container'));
      my @tweetimage = map {$_->findvalues(".//img/\@src")} @$mediadivs;
      @tweetimage = flat @tweetimage;
      my $fullname = $header->findvalue('./a/span/b' . class_contains("ProfileTweet-fullname"));
      my $username = $header->findvalue('./a/span/span' . class_contains("ProfileTweet-screenname"));
      $username =~ s{<[^>]+>}{}g;
      $username =~ s{^\s+}{};
      $username =~ s{\s+$}{};
      my $title = $body;
      $title =~ s{A\[}{A\[$username: }; # yuk, prepend username to title
      if ($username !~ /\@$user/i) {
          $body =~ s{A\[}{A\[$username: };
      }
      # Make links like https://kiza.eu/software/snownews/snowscripts/extensions/script/twitterlinks/source/
      $body =~ s{(https?://[^>"<  ]+)(?=&#xA0;)}{<a href="$1">$1</a>}g;
      $body =~ s{(?<!")(https?://[^>"<  ]+)}{<a href="$1">$1</a>}g;
      $body =~ s{@([a-zA-Z0-9_]*)}{<a href="https://twitter.com/$1">\@$1</a>}g;
      $body =~ s{( |^)#([a-zA-Z0-9_&#;]+)}{$1<a href="https://twitter.com/hashtag/$2">#$2</a>}g;

      if (@tweetimage) {
          foreach(@tweetimage) {
              $body = $body . "<br /><img src=\"$_\" />";
          }
      }

      $title = "<![CDATA[" . $title . "]]>";
      $body = "<![CDATA[" . $body . "]]>";

      my $uri = $BASEURL . $header->findvalue('./span' 
                                  . '/a'
                                  . class_contains("ProfileTweet-timestamp") 
                                  . '/@href'
      );  
      my $timestamp = $header->findvalue('./span' 
                      . '/a'
                      . class_contains("ProfileTweet-timestamp") 
                      . '/span/@data-time'
      );  

      my $pub_date = strftime("%a, %d %b %Y %H:%M:%S %z", localtime($timestamp));

      push @items, {
        username => $username,
        fullname => $fullname,
        link => $uri,
        guid => $uri,
        title => $title,
        description => $body,
        timestamp => $timestamp,
        pubDate => $pub_date,
      }
    }
	}
  else {
    $tree->delete; 
    err("Can't gather tweets for that user",404);
    next;
  }
  $tree->delete; 

	# now print as an rss feed, with header
print<<ENDHEAD
Content-type: application/rss+xml
Cache-control: max-age=$max_age

<?xml version="1.0" encoding="UTF-8"?>
<rss xmlns:atom="http://www.w3.org/2005/Atom" xmlns:georss="http://www.georss.org/georss" xmlns:twitter="http://api.twitter.com" xmlns:dc="http://purl.org/dc/elements/1.1/" version="2.0">
  <channel>
    <title>Twitter Search / $user </title>
    <link>https://twitter.com/$user</link>
    <description>Twitter feed for: $user. Generated by TwitRSS.me</description>
    <language>en-us</language>
    <ttl>40</ttl>
    <image>
        <url>$feedavatar</url>
    </image>
ENDHEAD
;

for (@items) {
  print<<ENDITEM
    <item>
      <title>$_->{title}</title>
      <dc:creator><![CDATA[$_->{fullname} ($_->{username})]]></dc:creator>
      <description>$_->{description}</description>
      <pubDate>$_->{pubDate}</pubDate>
      <guid>$_->{guid}</guid>
      <link>$_->{link}</link>
      <twitter:source/>
      <twitter:place/>
    </item>
ENDITEM
;
}

print<<ENDRSS
  </channel>
</rss>      
ENDRSS
;
}

sub class_contains {
  my $classname = shift;
  "[contains(concat(' ',normalize-space(\@class),' '),' $classname ')]";
}

sub err {
	my ($msg,$status) = (shift,shift);
	print<<ENDHEAD
Content-type: text/html
Status: $status
Cache-control: max-age=86400
Refresh: 10; url=http://twitrss.me

<html><head></head><body><h2>ERR: $msg</h2><p>Redirecting you back to <a href="http://twitrss.me">TwitRSS.me</a> in a few seconds. You might have spelled the username wrong or something</p></body></html>
ENDHEAD
;
}
