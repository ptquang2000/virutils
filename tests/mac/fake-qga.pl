#!/usr/bin/env perl
# tests/mac/fake-qga.pl -- a stand-in qemu-ga behind a stand-in qemu chardev,
# on a Unix socket, for tests/mac/agent.sh. tests/win/fake-qga.ps1 on a loopback
# port is the same fake for the Windows driver; see it for what is copied and
# why (docs/qga-multi-client.md): one client at a time, a listen backlog of 1,
# replies strictly in order, and a reply whose client has gone delivered to
# whoever connects next.
#
#   fake-qga.pl SOCKET LOG [rejectid] [stale=N] [boot=MS]
#
# Commands: guest-sync-delimited, guest-sync, guest-ping, guest-get-osinfo,
# guest-exec / guest-exec-status (the "output" is the argv, joined), and two of
# its own: guest-echo returns its arguments, and guest-slow returns them after
# arguments.ms. "id" is echoed -- or, with rejectid, a request carrying one is
# refused, as virtio-win's qemu-ga 7.6.2 does.
use strict;
use warnings;
use IO::Socket::UNIX;
use JSON::PP;
use Time::HiRes qw(time sleep);

my ($path, $log, @opt) = @ARGV;
my %o = map { /^(\w+)=(.*)$/ ? ($1 => $2) : ($_ => 1) } @opt;
my $json = JSON::PP->new->canonical;
$SIG{PIPE} = 'IGNORE';

unlink $path;
my $srv = IO::Socket::UNIX->new(Type => SOCK_STREAM(), Local => $path, Listen => 1)
    or die "listen $path: $!";
my $t0 = time;
sub logline { open(my $f, '>>', $log) or return; print $f "$_[0]\n"; close $f; }
logline('ready');

my (%procs, @carry);
my $next = 1000;
my $c;

sub out {
    my ($text, $delim) = @_;
    my $b = ($delim ? "\xff" : '') . $text . "\n";
    # A write to a peer that has gone fails here, and qemu would hand the
    # reply to the next client.
    push @carry, $b unless defined syswrite($c, $b);
}

sub answer {
    my ($req) = @_;
    my $a = $req->{arguments} // {};
    my $x = $req->{execute};
    return { return => $a->{id} }                if $x eq 'guest-sync';
    return { return => {} }                      if $x eq 'guest-ping';
    return { return => { id => 'mswindows' } }   if $x eq 'guest-get-osinfo';
    return { return => $a }                      if $x eq 'guest-echo';
    if ($x eq 'guest-slow') { sleep($a->{ms} / 1000); return { return => $a }; }
    if ($x eq 'guest-exec') {
        $next++;
        $procs{$next} = { text => join(' ', @{ $a->{arg} // [] }), polls => $next % 3 };
        return { return => { pid => $next } };
    }
    if ($x eq 'guest-exec-status') {
        my $p = $procs{ $a->{pid} // 0 }
            or return { error => { class => 'GenericError', desc => "Invalid parameter 'pid'" } };
        if ($p->{polls}-- > 0) { return { return => { exited => JSON::PP::false } }; }
        delete $procs{ $a->{pid} };
        require MIME::Base64;
        return { return => { exited => JSON::PP::true, exitcode => 0,
                             'out-data' => MIME::Base64::encode_base64("$p->{text}\r\n", '') } };
    }
    return { error => { class => 'CommandNotFound', desc => "The command $x has not been found" } };
}

while (1) {
    $c = $srv->accept or next;
    logline(sprintf 'connect %d', (time - $t0) * 1000);
    syswrite($c, $_) for @carry;
    @carry = ();
    out(qq({"return": {"stale": $_}, "id": 77$_})) for 0 .. ($o{stale} // 0) - 1;
    my $line = '';
    while (1) {
        my $wait = ($o{boot} // 0) / 1000 - (time - $t0);
        if ($wait > 0) { sleep($wait < 0.2 ? $wait : 0.2); next; }
        my $n = sysread($c, my $buf, 4096);
        last unless $n;
        for my $ch (split //, $buf) {
            if ($ch eq "\xff") { $line = ''; next; }
            if ($ch ne "\n") { $line .= $ch; next; }
            my $text = $line; $line = '';
            next unless $text =~ /\S/;
            my $req = eval { $json->decode($text) };
            if (!$req || ref $req ne 'HASH' || !defined $req->{execute}) {
                out('{"error": {"class": "GenericError", "desc": "Invalid JSON syntax"}}');
                next;
            }
            if ($req->{execute} eq 'guest-sync-delimited') {
                out(qq({"return": $req->{arguments}{id}}), 1);
                next;
            }
            if ($o{rejectid} && exists $req->{id}) {
                out(q({"error": {"class": "GenericError", "desc": "QMP input object member 'id' is unexpected"}}));
                next;
            }
            my $ans = answer($req);
            $ans->{id} = $req->{id} if exists $req->{id};
            out($json->encode($ans));
        }
    }
    close $c;
}
