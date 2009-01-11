# This lib/HTTP/Daemon file contains definitions for HTTP::Daemon,
# HTTP::Daemon::ClientConn, HTTP::Request and HTTP::Response.
# Normally each class would be in a separate file, but they were
# combined here to be able to start using them easily.

class HTTP::Daemon
{
    has Str  $.host;
    has Int  $.port;
    has Bool $!running;
    has Str  $!temporary_prog;
    has Bool $!accepted;

    method daemon {
        $!running = Bool::True;
        while $!running {
            # my Str $command = "$*PROG --request"; # Rakudo needs this
            my Str $command = "{$!temporary_prog} --request";
            run( "netcat -c '$command' -l -s {$.host} -p {$.port}" );
            # spawning netcat here is a temporary measure until
            # Rakudo gets socket(), listen(), accept() etc.
        }
    }

    # This works around the lack of a $*PROG variable. See daemon above.
    method temporary_set_prog( Str $prog ) {
        $!temporary_prog = $prog;
    }

    # Where to find this server - used for messages, logs, hyperlinks
    method url { return "http://{$.host}:{$.port}/"; }

    # Waits to receive a browser request and then returns.
    # Because netcat exits after a single receive + transmit, this
    # routine is altered from the normal endless loop. It sets a flag when
    # it has returned one client connection and always returns undef
    # when called a second time, because the netcat client connection
    # will be gone. This is also why HTTP 1.1 chunked transfer cannot
    # be done with netcat.
    method accept {
        if defined $!accepted { return undef; }
        else {
            $!accepted = Bool::True;
            my HTTP::Daemon::ClientConn $clientconn .= new;
            return $clientconn;
        }
    }
}

# This maintains the connected TCP session and handles chunked data
# transfer, but Rakudo and netcat end the session after every request.
class HTTP::Daemon::ClientConn {
    has HTTP::Request $.request is rw;
    has Bool $!gave_request;
    
    method get_request {
        if defined $!gave_request { return undef; }
        else {
            $!gave_request = Bool::True;
            my Str $line = =$*IN;
            my @fields = $line.split(' ');
            # $*ERR.say: "-------------------";
            my Str $headerline;
            my %headers;
            repeat {
                $headerline = =$*IN;
                # $*ERR.say: "HEADERLINE: $headerline";
                # if $headerline ~~ HTTP::headerline {
                #     my $key   = $/<key>;
                #     my $value = $/<value>;
                #     $*ERR.say: "MATCHED! KEY '$key'  VALUE '$value'";
                # }
                # sorry, below isn't perlish, but above is broken
                my $index = $headerline.index(':');
                if $index {
                    my $key   = $headerline.substr( 0, $index );
                    my $value = $headerline.substr( $index + 2 );
                    %headers{$key} = $value;
                }
            } until $headerline eq ""; # blank line terminates
            return HTTP::Request.new(
                req_url    => HTTP::url.new( path=>@fields[1] ),
                headers    => HTTP::Headers.new( header_values => %headers ),
                req_method => @fields[0]
            );
        }
    }

    # no plan here - just provide what the Perl 5 docs specify
    method send_basic_header {
        self.send_status_line;
    }

    multi method send_status_line(
        Int $status?   = 200,
        Str $message?  = 'OK',
        Str $protocol? = 'HTTP/1.0'
    ) { say "$protocol $status $message"; }

    method send_crlf {
        say "";
    }

    method send_response( Str $content ) {
        self.send_basic_header;
        self.send_crlf;
        say $content;
    }

    method send_file_response( Str $filename ) {
        self.send_basic_header;
        self.send_crlf;
        self.send_file( $filename );
    }

    # untested so far
    method send_file( Str $filename ) {
        my $contents = slurp( $filename );
        print $contents;
    }

    # not sure whether this and the next method might be inefficient
    multi method send_error( Int $status ) {
        my %message = (
            200 => 'OK',
            403 => 'RC_FORBIDDEN',
            404 => 'RC_NOTFOUND',
            500 => 'RC_INTERNALERROR',
            501 => 'RC_NOTIMPLEMENTED'
        );
        self.send_error( $status, %message{$status} );
    }

    multi method send_error( Str $message ) {
        my %status = (
            'OK'                => 200,
            'RC_FORBIDDEN'      => 403,
            'RC_NOTFOUND'       => 404,
            'RC_INTERNALERROR'  => 500,
            'RC_NOTIMPLEMENTED' => 501
        );
        self.send_error( %status{$message}, $message );
    }

    multi method send_error( Int $status, Str $message ) {
        self.send_status_line( $status, $message );
        self.send_crlf;
        say "<title>$status $message</title>";
        say "<h1>$status $message</h1>";
    }
}

class HTTP::Request {
    has HTTP::Headers $!headers;
    has HTTP::url     $!req_url;
    has Str           $.uurl;
    has Str           $.req_method  is rw;

    method url {
        return $!req_url;
    }
    method header( Str $fieldname ) {
        return $!headers.header( $fieldname );
    }
    method header_field_names {
        return $!headers.header_field_names;
    }
}

class HTTP::Response {
}

# an only partial emulation of the Perl 5 HTTP::Headers design - no tuits!
class HTTP::Headers {
    has %!header_values;    
    method header( Str $fieldname ) {
        return %!header_values{ $fieldname };
    }
    method header_field_names {
        return %!header_values.keys;
    }
}

class HTTP::url {
    has $.path;
}

grammar HTTP::headerline {
    regex TOP { <key> ':' <.sp>* <value> }
    regex key { \S+ }
    regex value { .+ } # or should that be .* to allow an "empty" value?
}

=begin pod

=head1 NAME
HTTP::Daemon - a (very) simple web server using Rakudo Perl 6

=head1 DESCRIPTION
You can make your own web server using L<doc:HTTP::Daemon> without using
Apache, IIS or any kind of mod_perl. You control (almost) everything the
web server does, let modules do the low level work and concentrate on
functional design. If your site is fairly code intensive, this solution
might be more efficient than sending all your data through another
server process.

Why bother when Apache is so popular? Think embedded web server, or
maybe an application web front end, or web services. Custom stuff.

This module shows how easily you can write a simple web server. Beware
though, writing an advanced web server is hard and might result in
Internet security breaches.

=head1 EXAMPLES
=head2 Small but working
=begin code
#!/usr/local/bin/perl6

use v6;
use HTTP_Daemon;
defined @*ARGS[0] && @*ARGS[0] eq '--request' ?? request() !! daemon();

# handle a single browser request, executed in a child process of netcat
sub request {
    my HTTP_Daemon $d .= new;
    while my HTTP_Daemon_ClientConn $c = $d.accept {
        while my HTTP_Request $r = $c.get_request {
            my $method = $r.method;
            if $r.method eq 'GET' {
                given $r.url.path {
                    when '/'             { root_dir( $c, $r ); }
                    when / ^ \/pub\/ $ / { pub_dir(  $c, $r ); }
                }
            }
            else {
                $c.send_error('RC_FORBIDDEN');
            }
        }
    }
}

# start the main server and enter the endless loop in the inner daemon.
sub daemon {
    my HTTP_Daemon $d .= new( host=>'127.0.0.1', port=>2080 );
    $d.temporary_set_prog( './test.pl' );
    say "Browse this Perl 6 web server at {$d.url}";
    $d.daemon();
}

# called from sub request for the '/' url
sub root_dir( HTTP_Daemon_ClientConn $c, HTTP_Request $r ) {
    my $content = q[<html><head><title>Hello</title>
<body><h1>Rakudo web server</h1>
Hello, world! This is root. Go to <a href="/pub/">pub</a>.
</body></html>];
    $c.send_response( $content );
}

# called from sub request for the '/pub/' url
sub pub_dir( HTTP_Daemon_ClientConn $c, HTTP_Request $r ) {
    my $content = q[<html><head><title>Hello</title>
<body><h1>Rakudo web server</h1>
Hello again, this is pub. Go <a href="/">Home</a>.
</body></html>];
    $c.send_response( $content );
}
=end code

=head2 Perl 5 HTTP::Daemon example converted to Perl 6
=begin code
#!/usr/local/bin/perl6

use v6;
use HTTP_Daemon;
defined @*ARGS[0] && @*ARGS[0] eq '--request' ?? request() !! daemon();

sub request {
    my HTTP_Daemon $d .= new;
    while my HTTP_Daemon_ClientConn $c = $d.accept {
        while my HTTP_Request $r = $c.get_request {
            if $r.method eq 'GET' and $r.url.path eq '/xyzzy' {
                # remember, this is *not* recommended practice :-)
                $c.send_file_response("/etc/passwd");
            }
            else {
                $c.send_error('RC_FORBIDDEN');
            }
        }
    }
}

sub daemon {
    my HTTP_Daemon $d .= new( host=>'127.0.0.1', port=>2080 );
    $d.temporary_set_prog( './test.pl' );
    say "Browse this Perl 6 web server at {$d.url}";
    $d.daemon();
}
=end code

=head1 DEPENDENCIES
Temporarily (see L<#TODO>) HTTP_Daemon depends on the L<man:netcat>
utility to receive and send on a TCP port.
On Debian based Linux distributions, this should set it up:

 sudo apt-get install netcat

=head1 TODO
Remove temporary_set_prog() when rakudo gets $*PROG.

=head1 BUGS
This L<doc:HTTP::Daemon> may give errors running with certain revisions
of Rakudo. They most recently working together in Rakudo r35309, but
r35366 fails in a segmentation fault.

=head1 SEE ALSO
L<man:netcat(1)> calls itself a TCP/IP swiss army knife.

HTTP 1.1 (L<http://www.ietf.org/rfc/rfc2616.txt>) describes all methods
and status codes.

=head1 AUTHOR
Martin Berends (mberends on CPAN github #perl6 and @flashmail.com).

=end pod
