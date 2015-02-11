use strict;

package Plugins::ShairTunes::Plugin;

use Plugins::ShairTunes::AIRPLAY;
use Plugins::ShairTunes::Utils;

use base qw(Slim::Plugin::OPMLBased);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Misc;
use Slim::Utils::Network;
use Slim::Networking::Async;
use Slim::Networking::Async::Socket;
use Slim::Networking::Async::Socket::HTTP;

use Config;
use Digest::MD5 qw(md5 md5_hex);
use MIME::Base64;

use IO::Socket::INET6;
use Crypt::OpenSSL::RSA;
use Net::SDP;
use IPC::Open2;

# create log categogy before loading other modules
my $log = Slim::Utils::Log->addLogCategory({
     'category'     => 'plugin.shairtunes',
     'defaultLevel' => 'ERROR',
     'description'  => getDisplayName(),
});

my $prefs = preferences('plugin.shairtunes');
my $hairtunes_cli = "";

my $airport_pem = join '', <DATA>;
my $rsa = Crypt::OpenSSL::RSA->new_private_key($airport_pem) || die "RSA private key import failed";

my %clients = ();
my %sockets = ();
my %players = ();
my %connections = ();

my $samplingRate = 44100;
my $positionRealTime = 0;
my $durationRealTime = 0;

my $title = "ShairTunes Title";
my $artist = "ShairTunes Artist";
my $album = "ShairTunes Album";
my $bitRate = $samplingRate." Hz"; 
my $cover = ""; 

my %airTunesMetaData = ( 
     artist => $artist,
     title => $title,
     album => $album,
     bitrate => $bitRate,
     cover => $cover,
     duration => $durationRealTime,
     position => $positionRealTime,
);

sub getAirTunesMetaData() {
     return %airTunesMetaData;
}

sub initPlugin() {
     my $class = shift;

     $log->info("Initialising " . $class->_pluginDataFor('version'));

     # Subscribe to player connect/disconnect messages
     Slim::Control::Request::subscribe(
          \&playerSubscriptionChange,
          [['client'],['new','reconnect','disconnect']]
     );
     
     return 1;
}

sub getDisplayName() { 
     return('PLUGIN_SHAIRTUNES')
}

sub shutdownPlugin() {
     return;
}

sub playerSubscriptionChange {
     my $request = shift;
     my $client  = $request->client;
	
     my $reqstr = $request->getRequestString();
     my $clientname = $client->name();

     $log->debug("request=$reqstr client=$clientname");
	
     if ( ($reqstr eq "client new") || ($reqstr eq "client reconnect") ) {
          $sockets{$client} = createListenPort();
          $players{$sockets{$client}} = $client;

          if ($sockets{$client}) {
               # Add us to the select loop so we get notified
               Slim::Networking::Select::addRead($sockets{$client}, \&handleSocketConnect);
 
               $clients{$client} = publishPlayer($clientname, "", $sockets{$client}->sockport());
          }
          else {
               $log->error("could not create ShairTunes socket for $clientname");
               delete $sockets{$client}
          }
     } elsif ($reqstr eq "client disconnect") {
          $log->debug("publisher for $clientname PID $clients{$client} will be terminated.");
          system "kill $clients{$client}";
          Slim::Networking::Select::removeRead($sockets{$client});
     }
}

sub createListenPort() {   
     my $listen;

     $listen   = new IO::Socket::INET6(
                         Listen => 1,
                         Domain => AF_INET6,
                         ReuseAddr => 1,
                         Proto => 'tcp',
                         );

    $listen ||= new IO::Socket::INET(
                         Listen => 1,
                         ReuseAddr => 1,
                         Proto => 'tcp',
                         );                         
    return $listen;
}

sub publishPlayer() {
     my ($apname, $password, $port) = @_;
     
     my $pid = fork();
        
     my $pw_clause = (length $password) ? "pw=true" : "pw=false";
     my @hw_addr = +(map(ord, split(//, md5($apname))))[0..5];

     if ($pid==0) {
          { exec( 
                    'avahi-publish-service',
                    join('', map { sprintf "%02X", $_ } @hw_addr) . "\@$apname",
                    "_raop._tcp",
                    $port,
                    "tp=UDP","sm=false","sv=false","ek=1","et=0,1","md=0,1,2","cn=0,1","ch=2","ss=16","sr=44100",$pw_clause,"vn=3","txtvers=1");
          };
          { exec(
                    'dns-sd', '-R',
                    join('', map { sprintf "%02X", $_ } @hw_addr) . "\@$apname",
                    "_raop._tcp",
                    ".",
                    $port,
                    "tp=UDP","sm=false","sv=false","ek=1","et=0,1","md=0,1,2","cn=0,1","ch=2","ss=16","sr=44100",$pw_clause,"vn=3","txtvers=1");
          };
          { exec(
                    'mDNSPublish',
                    join('', map { sprintf "%02X", $_ } @hw_addr) . "\@$apname",
                    "_raop._tcp",
                    $port,
                    "tp=UDP","sm=false","sv=false","ek=1","et=0,1","md=0,1,2","cn=0,1","ch=2","ss=16","sr=44100",$pw_clause,"vn=3","txtvers=1");
          };
          die "could not run avahi-publish-service nor dns-sd nor mDNSPublish";
     }
     
     return $pid;
}

sub handleSocketConnect() {
     my $socket = shift;
     my $player = $players{$socket};

     my $bytesToRead = 4096;
     
     my $new = $socket->accept;
     $log->info("New connection from ".$new->peerhost);
    
     Slim::Utils::Network::blocking($new, 0);
     ${*$new}{BYTESTOREAD} = $bytesToRead;
     $connections{$new} = {socket => $socket, player => $player};

     # Add us to the select loop so we get notified
     Slim::Networking::Select::addRead($new, \&handleSocketRead);
}

sub handleSocketRead() {
     my $socket = shift;
     
     if( eof($socket) ) {
          $log->debug("Closed: ".$socket);

          Slim::Networking::Select::removeRead($socket);	

          close $socket;
          delete $connections{$socket} 
     }
     else {
          conn_read_data($socket);
     }
}

sub conn_read_data {
     my $socket = shift;
     
     my $conn = $connections{$socket};
                  
     my $contentBody;
     my $contentLength = 0;
     my $buffer;
     
#     my $bytesToRead = 4096;
     my $bytesToRead = ${*$socket}{BYTESTOREAD}; 
     
     ### This while loop is a workaround until this thing is implemented correctly into lms
#     while(42) {
          read($socket, my $incoming, $bytesToRead , 0);
          $buffer .= $incoming;
                         
          ### Has the data a new line -> then we have the header
          if ($buffer =~ /\r\n\r\n/sm) {
               $log->debug("Got the header.");
               if ( $buffer =~ /Content-Length:\s(\d+)/) {
                    $contentLength = $1;
               }
               $log->debug("Content Length is: " .$contentLength);
               $buffer =~ /(.*)\r\n\r\n/sm;
               #$log->debug("Header is:\n" .$1);
          }
          else {
               ### Header missing -> Back to LMS.
               $log->debug("Header not yet completely received. Waiting...");
          }
          ### Check length of data after new lines -> Content-Lengths
          if ($buffer =~ /\r\n\r\n(.*)/sm) {
               $contentBody = $1;
               $log->debug("Content Length received: " .length($contentBody));
               ### if the content-length does not match -> return to LMS
               if(length($contentBody) != $contentLength) {
                    ### Content missing -> Back to LMS.
                    $log->debug("Content not yet completely received. Waiting...");
                    ### In the next loop just read whats missing.
                    $bytesToRead = $contentLength - length($contentBody);
               }
               else {
                    $log->debug("Got the content.");
                    $buffer =~ /\r\n\r\n(.*)/sm;
                    #$log->debug("Content is:\n" .$1);
                    ### We are complete -> Data Handling...
                    $bytesToRead = ${*$socket}{BYTESTOREAD};
#                    last;
               }
          }
#     }
     $log->debug("And now to the request handler...");
     ### START: Not yet updated.
     $conn->{data} = $buffer;
     conn_handle_interface($socket, $conn);
     ### END: Not yet updated.
}

### Interface to original request code.
sub conn_handle_interface {
     my $socket = shift;
     my $conn = $connections{$socket};

     $log->debug("Handling Data...");

     if ($conn->{data} =~ /\r\n\r\n/) {
          my $req_data = substr($conn->{data}, 0, $+[0], '');
          $conn->{req} = HTTP::Request->parse($req_data);
          
          $conn->{req}->content($conn->{data});
          conn_handle_request($socket, $conn);
    }
}

sub conn_handle_request {
     my ($socket, $conn) = @_;

     my $req = $conn->{req};
     my $resp = HTTP::Response->new(200);
    
    $resp->request($req);
    $resp->protocol($req->protocol);

    $resp->header('CSeq', $req->header('CSeq'));
    $resp->header('Audio-Jack-Status', 'connected; type=analog');
    
    if (my $chall = $req->header('Apple-Challenge')) {
        my $data = decode_base64($chall);
        my $ip = $socket->sockhost;
        if ($ip =~ /((\d+\.){3}\d+)$/) { # IPv4
            $data .= join '', map { chr } split(/\./, $1);
        } else {
            $data .= Plugins::ShairTunes::Utils::ip6bin($ip);
        }

        my @hw_addr = +(map(ord, split(//, md5($conn->{player}->name()))))[0..5];

        $data .= join '', map { chr } @hw_addr;
        $data .= chr(0) x (0x20-length($data));

        $rsa->use_pkcs1_padding;    # this isn't hashed before signing
        my $signature = encode_base64 $rsa->private_encrypt($data), '';
        $signature =~ s/=*$//;
        $resp->header('Apple-Response', $signature);
    }

    if (length $conn->{password}) {
        if (!Plugins::ShairTunes::Utils::digest_ok($req, $conn)) {
            my $nonce = md5_hex(map { rand } 1..20);
            $conn->{nonce} = $nonce;
            my $apname = $conn->{player}->name();
            $resp->header('WWW-Authenticate', "Digest realm=\"$apname\", nonce=\"$nonce\"");
            $resp->code(401);
            $req->method('DENIED');
        }
    }

    for ($req->method) {
        /^OPTIONS$/ && do {
            $resp->header('Public', 'ANNOUNCE, SETUP, RECORD, PAUSE, FLUSH, TEARDOWN, OPTIONS, GET_PARAMETER, SET_PARAMETER');
            last;
        };

        /^ANNOUNCE$/ && do {
                my $sdp = Net::SDP->new($req->content);
                my $audio = $sdp->media_desc_of_type('audio');

                die("no AESIV") unless my $aesiv = decode_base64($audio->attribute('aesiv'));
                die("no AESKEY") unless my $rsaaeskey = decode_base64($audio->attribute('rsaaeskey'));
                $rsa->use_pkcs1_oaep_padding;
                my $aeskey = $rsa->decrypt($rsaaeskey) || die "RSA decrypt failed";

                $conn->{aesiv} = $aesiv;
                $conn->{aeskey} = $aeskey;
                $conn->{fmtp} = $audio->attribute('fmtp');
                last;
        };

        /^SETUP$/ && do {
            my $transport = $req->header('Transport');
            $transport =~ s/;control_port=(\d+)//;
            my $cport = $1;
            $transport =~ s/;timing_port=(\d+)//;
            my $tport = $1;
            $transport =~ s/;server_port=(\d+)//;
            my $dport = $1;
            $resp->header('Session', 'DEADBEEF');

            my %dec_args = (
                iv      =>  unpack('H*', $conn->{aesiv}),
                key     =>  unpack('H*', $conn->{aeskey}),
                fmtp    => $conn->{fmtp},
                cport   => $cport,
                tport   => $tport,
                dport   => $dport,
            );

            my $dec = '"' . Plugins::ShairTunes::Utils::helperBinary() . '"' . join(' ', '', map { sprintf "%s '%s'", $_, $dec_args{$_} } keys(%dec_args));
            $log->debug("decode command: $dec");
            
            my $decoder = open2(my $dec_out, my $dec_in, $dec);

            $conn->{decoder_pid} = $decoder;
            $conn->{decoder_fh} = $dec_in;
            
            my $portdesc = <$dec_out>;
            die("Expected port number from decoder; got $portdesc") unless $portdesc =~ /^port: (\d+)/;
            my $port = $1;

            my $portdesc = <$dec_out>;
            die("Expected cport number from decoder; got $portdesc") unless $portdesc =~ /^cport: (\d+)/;
            my $cport = $1;

            my $portdesc = <$dec_out>;
            die("Expected hport number from decoder; got $portdesc") unless $portdesc =~ /^hport: (\d+)/;
            my $hport = $1;
            
            
            $log->info("launched decoder: $decoder on ports: $port/$cport/$hport");
            $resp->header('Transport', $req->header('Transport') . ";server_port=$port");

            my $host = Slim::Utils::Network::serverAddr();
            my $url = "airplay://$host:$hport/stream.wav";
            my $client = $conn->{player};
            my @otherclients = grep { $_->name ne $client->name and $_->power }
                                    $client->syncGroupActiveMembers();
            foreach my $otherclient (@otherclients)
            {
                $log->info('turning off: ' . $otherclient->name);
                $otherclient->display->showBriefly({line => ['AirPlay streaming to ' . $client->name . ':', 'Turning this player off']});
                $otherclient->execute(['power', 0]);
            }
            $conn->{player}->execute( [ 'playlist', 'play', $url ] );
            
            last;
        };

        /^RECORD$/ && last;
        /^FLUSH$/ && do {
            my $dfh = $conn->{decoder_fh};
            print $dfh "flush\n";
			$conn->{player}->execute( [ 'pause' ] );
            last;
        };
        /^TEARDOWN$/ && do {
            $resp->header('Connection', 'close');
            close $conn->{decoder_fh};
            $conn->{player}->execute( [ 'stop' ] );
            last;
        };
        /^SET_PARAMETER$/ && do {
			if ( $req->header('Content-Type') eq "text/parameters" ) {
            	my @lines = split(/[\r\n]+/, $req->content);
                	$log->debug("SET_PARAMETER req: " . $req->content);
            	my %content = map { /^(\S+): (.+)/; (lc $1, $2) } @lines;
            	my $cfh = $conn->{decoder_fh};
            	if (exists $content{volume}) {
                	my $volume = $content{volume};
                	my $percent = 100 + ($volume * 3.35);
                
                	$conn->{player}->execute( [ 'mixer', 'volume', $percent ] );
                            
                	$log->debug("sending-> vol: ". $percent);
				}
				elsif (exists $content{progress}) {
					my ( $start, $curr, $end ) = split( /\//, $content{progress} );
					$positionRealTime = ( $curr - $start ) / $samplingRate;
					$durationRealTime = ( $end - $start ) / $samplingRate;

					$airTunesMetaData{duration} = $durationRealTime;
					$airTunesMetaData{position} = $positionRealTime;

					$log->debug("Duration: ". $durationRealTime ."; Position: ". $positionRealTime);
				} 
				else {
					$log->error("unable to perform content for req: " . $req->content);
				}
			}
			elsif ( $req->header('Content-Type') eq "application/x-dmap-tagged" ) {
				$log->debug("DMAP DATA found. Length: " .length($req->content));
                    #my %dmapData = Plugins::ShairTunes::Utils::getDmapData($req->content);
                    #$airTunesMetaData{artist} = $dmapData{artist};
                    #$airTunesMetaData{album} = $dmapData{album};
                    #$airTunesMetaData{title} = $dmapData{title};
                    
			}
			elsif ( $req->header('Content-Type') eq "image/jpeg" ) {
				$log->debug("IMAGE DATA found.");
                    my ($volume, $directory, $file) = File::Spec->splitpath(__FILE__);
                    my $fileName = $directory. "HTML/EN/plugins/ShairTunes/html/images/cover.jpg";
                    
                    #open(fileHandle, '>', $fileName);
                    #binmode(fileHandle);
                    #print(fileHandle $req->content);
                    #close(fileHandle);
                    
                    #$airTunesMetaData{cover} = $fileName;
			}
			else {
				$log->error("unable to perform content");
			}
            last;
        };
        /^GET_PARAMETER$/ && do {
            my @lines = split /[\r\n]+/, $req->content;
                $log->debug("GET_PARAMETER req: " . $req->content);
                
            my %content = map { /^(\S+): (.+)/; (lc $1, $2) } @lines;
            
            last;
        
        };
        /^DENIED$/ && last;
        die("Unknown method: $_");
    }

    #$log->debug("\n\nPLAYER_MESSAGE_START: \n" .$resp->as_string("\r\n"). "\nPLAYER_MESSAGE_END\n\n");
    
    print $socket $resp->as_string("\r\n");
    $socket->flush;

}

1;

__DATA__
-----BEGIN RSA PRIVATE KEY-----
MIIEpQIBAAKCAQEA59dE8qLieItsH1WgjrcFRKj6eUWqi+bGLOX1HL3U3GhC/j0Qg90u3sG/1CUt
wC5vOYvfDmFI6oSFXi5ELabWJmT2dKHzBJKa3k9ok+8t9ucRqMd6DZHJ2YCCLlDRKSKv6kDqnw4U
wPdpOMXziC/AMj3Z/lUVX1G7WSHCAWKf1zNS1eLvqr+boEjXuBOitnZ/bDzPHrTOZz0Dew0uowxf
/+sG+NCK3eQJVxqcaJ/vEHKIVd2M+5qL71yJQ+87X6oV3eaYvt3zWZYD6z5vYTcrtij2VZ9Zmni/
UAaHqn9JdsBWLUEpVviYnhimNVvYFZeCXg/IdTQ+x4IRdiXNv5hEewIDAQABAoIBAQDl8Axy9XfW
BLmkzkEiqoSwF0PsmVrPzH9KsnwLGH+QZlvjWd8SWYGN7u1507HvhF5N3drJoVU3O14nDY4TFQAa
LlJ9VM35AApXaLyY1ERrN7u9ALKd2LUwYhM7Km539O4yUFYikE2nIPscEsA5ltpxOgUGCY7b7ez5
NtD6nL1ZKauw7aNXmVAvmJTcuPxWmoktF3gDJKK2wxZuNGcJE0uFQEG4Z3BrWP7yoNuSK3dii2jm
lpPHr0O/KnPQtzI3eguhe0TwUem/eYSdyzMyVx/YpwkzwtYL3sR5k0o9rKQLtvLzfAqdBxBurciz
aaA/L0HIgAmOit1GJA2saMxTVPNhAoGBAPfgv1oeZxgxmotiCcMXFEQEWflzhWYTsXrhUIuz5jFu
a39GLS99ZEErhLdrwj8rDDViRVJ5skOp9zFvlYAHs0xh92ji1E7V/ysnKBfsMrPkk5KSKPrnjndM
oPdevWnVkgJ5jxFuNgxkOLMuG9i53B4yMvDTCRiIPMQ++N2iLDaRAoGBAO9v//mU8eVkQaoANf0Z
oMjW8CN4xwWA2cSEIHkd9AfFkftuv8oyLDCG3ZAf0vrhrrtkrfa7ef+AUb69DNggq4mHQAYBp7L+
k5DKzJrKuO0r+R0YbY9pZD1+/g9dVt91d6LQNepUE/yY2PP5CNoFmjedpLHMOPFdVgqDzDFxU8hL
AoGBANDrr7xAJbqBjHVwIzQ4To9pb4BNeqDndk5Qe7fT3+/H1njGaC0/rXE0Qb7q5ySgnsCb3DvA
cJyRM9SJ7OKlGt0FMSdJD5KG0XPIpAVNwgpXXH5MDJg09KHeh0kXo+QA6viFBi21y340NonnEfdf
54PX4ZGS/Xac1UK+pLkBB+zRAoGAf0AY3H3qKS2lMEI4bzEFoHeK3G895pDaK3TFBVmD7fV0Zhov
17fegFPMwOII8MisYm9ZfT2Z0s5Ro3s5rkt+nvLAdfC/PYPKzTLalpGSwomSNYJcB9HNMlmhkGzc
1JnLYT4iyUyx6pcZBmCd8bD0iwY/FzcgNDaUmbX9+XDvRA0CgYEAkE7pIPlE71qvfJQgoA9em0gI
LAuE4Pu13aKiJnfft7hIjbK+5kyb3TysZvoyDnb3HOKvInK7vXbKuU4ISgxB2bB3HcYzQMGsz1qJ
2gG0N5hvJpzwwhbhXqFKA4zaaSrw622wDniAK5MlIE0tIAKKP4yxNGjoD2QYjhBGuhvkWKY=
-----END RSA PRIVATE KEY-----
