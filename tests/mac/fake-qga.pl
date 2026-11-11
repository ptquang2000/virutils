#!/usr/bin/env perl
# tests/mac/fake-qga.pl -- a stand-in qemu-ga behind a stand-in qemu chardev,
# on a Unix socket, for tests/mac/agent.sh. tests/win/fake-qga.ps1 on a loopback
# port is the same fake for the Windows driver; see it for what is copied and
# why (docs/qga-multi-client.md): one client at a time, a listen backlog of 1,
# replies strictly in order, and a reply whose client has gone delivered to
# whoever connects next.
#
#   fake-qga.pl SOCKET LOG [rejectid] [stale=N] [boot=MS] [model]
#
# Commands: guest-sync-delimited, guest-sync, guest-ping, guest-get-osinfo,
# guest-exec / guest-exec-status (the "output" is the argv, joined), and two of
# its own: guest-echo returns its arguments, and guest-slow returns them after
# arguments.ms. "id" is echoed -- or, with rejectid, a request carrying one is
# refused, as virtio-win's qemu-ga 7.6.2 does.
#
# With model, guest-exec and guest-exec-status are instead a model of qemu-ga's
# exec bookkeeping (qga/commands.c, docs/qga-exec-records.md), the one
# tests/win/exec.ps1 builds in PowerShell: a record per guest-exec, appended;
# guest-exec-status answers from the *first* record with that pid and drops it
# once it reports it exited; a pid the guest freed is handed to the next
# process while an old record for it is still there. Every guest-exec is given
# the pid test-reset named. The test drives it with three commands of its own:
#
#   test-reset {pid, out, rc, signal, polls, quiet, oldmsg}  what the next
#       guest-exec gets: its pid, its stdout (after the nonce, which is printed
#       unless quiet, as a real wrapper prints it), its exit code or signal, and
#       how many polls say it is still running. oldmsg answers an unknown pid with
#       the generic "Invalid parameter 'pid'". Clears the records and the log.
#   test-add-rec {pid, finished, capture, rc, out, polls}  a record left behind
#   test-state  {recs: [pid...], execs: [{pid, text, capture, input}...]}
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
my (@recs, @execs, %next);
my $next = 1000;
my $c;

sub out {
    my ($text, $delim) = @_;
    my $b = ($delim ? "\xff" : '') . $text . "\n";
    # A write to a peer that has gone fails here, and qemu would hand the
    # reply to the next client.
    push @carry, $b unless defined syswrite($c, $b);
}

sub b64d { require MIME::Base64; return MIME::Base64::decode_base64($_[0] // ''); }
sub b64e { require MIME::Base64; return MIME::Base64::encode_base64($_[0], ''); }

# The model's guest-exec and guest-exec-status, and its three test commands;
# undef for anything else.
sub model {
    my ($x, $a) = @_;
    if ($x eq 'test-reset') {
        @recs = (); @execs = ();
        %next = (pid => 5512, out => '', rc => 0, polls => 1, %$a);
        return { return => {} };
    }
    if ($x eq 'test-add-rec') {
        push @recs, { pid => $a->{pid}, finished => $a->{finished} ? 1 : 0,
                      capture => $a->{capture} ? 1 : 0, rc => $a->{rc} // 0,
                      out => $a->{out} // '', polls => $a->{polls} // 0 };
        return { return => {} };
    }
    if ($x eq 'test-state') {
        return { return => { recs => [ map { $_->{pid} } @recs ], execs => \@execs } };
    }
    if ($x eq 'guest-exec') {
        my @argv = @{ $a->{arg} // [] };
        # powershell's script is UTF-16LE base64, the last argument; anything
        # else is read as it was sent.
        my $text = join(' ', @argv);
        if (($a->{path} // '') =~ /powershell/i && @argv) {
            require Encode;
            my $d = eval { Encode::decode('UTF-16LE', b64d($argv[-1])) };
            $text = Encode::encode('UTF-8', $d) if defined $d && length $d;
        }
        my $capture = $a->{'capture-output'} ? 1 : 0;
        my $in = exists $a->{'input-data'} ? b64d($a->{'input-data'}) : '';
        push @execs, { pid => $next{pid}, text => $text,
                       capture => $capture ? JSON::PP::true : JSON::PP::false, input => $in };
        # A real guest prints the wrapper's nonce first, unless the process
        # died before its script ran.
        my $out = $next{out};
        $out = "virutil-call $1\r\n$out" if $text =~ /virutil-call ([0-9a-f]{32})/ && !$next{quiet};
        push @recs, { pid => $next{pid}, finished => 0, capture => $capture,
                      rc => $next{rc}, signal => $next{signal}, out => $out, polls => $next{polls} };
        return { return => { pid => $next{pid} } };
    }
    if ($x eq 'guest-exec-status') {
        my $pid = $a->{pid} // 0;
        my ($i) = grep { $recs[$_]{pid} == $pid } 0 .. $#recs;
        if (!defined $i) {
            return { error => { class => 'GenericError', desc => "Invalid parameter 'pid'" } } if $next{oldmsg};
            return { error => { class => 'GenericError', desc => "PID $pid does not exist" } };
        }
        my $r = $recs[$i];
        if (!$r->{finished}) {
            if ($r->{polls} > 0) { $r->{polls}--; return { return => { exited => JSON::PP::false } }; }
            $r->{finished} = 1;
        }
        my %st = (exited => JSON::PP::true);
        if (defined $r->{signal}) { $st{signal} = $r->{signal} + 0; }
        else                      { $st{exitcode} = $r->{rc} + 0; }
        $st{'out-data'} = b64e($r->{out}) if $r->{capture} && length $r->{out};
        splice @recs, $i, 1;
        return { return => \%st };
    }
    return undef;
}

sub answer {
    my ($req) = @_;
    my $a = $req->{arguments} // {};
    my $x = $req->{execute};
    if ($o{model}) { my $m = model($x, $a); return $m if $m; }
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
