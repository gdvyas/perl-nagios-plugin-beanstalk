package Nagios::Plugin::Beanstalk;
# vim: ts=8:sw=2:expandtab

use strict;
use warnings;

use base qw(Nagios::Plugin);

use Nagios::Plugin;
use Beanstalk::Client;

our $VERSION = '0.01';


sub new {
  my $class = shift;

  my $usage = <<'USAGE';
Usage: check_beanstalkd -H <host> [-p <port>] [-t <tube>] [-w <warn_time>] [-c <crit_time>]
USAGE

  my $self = $class->SUPER::new(
    shortname => 'beanstalkd',
    usage     => $usage,
    version   => $VERSION,
    url       => 'http://search.cpan.org/dist/Nagios-Plugin-Beanstalk/check_beanstalkd',
    license =>
      qq|This library is free software, you can redistribute it and/or modify\nit under the same terms as Perl itself.|,
  );

  $self->_add_beanstalk_options;

  return $self;
}


sub _add_beanstalk_options {
  my ($self) = @_;

  my @args = (
    { spec => 'hostname|H=s',
      help =>
        qq|-H, --hostname=ADDRESS\n  Host name, IP Address, or unix socket (must be an absolute path)|,
      required => 1,
    },
    { spec => 'port|p=i',
      help => qq|-p, --port=INTEGER\n  Port number (default: 389)|,
    },
    { spec => 'tube|t=s@',
      help => qq|-t [--tube]\n  tube to check, can give multiple|,
    },
    { spec => 'warning|w=f',
      help => qq|-w, --warning=DOUBLE\n  Response time to result in warning status (seconds)|,
    },
    { spec => 'critical|c=f',
      help => qq|-c, --critical=DOUBLE\n  Response time to result in critical status (seconds)|,
    },
  );

  $self->add_arg(%$_) for (@args);
}


sub run {
  my ($self) = @_;

  $self->getopts;

  my $opts = $self->opts;

  my $hostname = $opts->get('hostname') || 'localhost';
  my $port = $opts->get('port');

  $hostname .= ":$port" if $port;

  my $client = Beanstalk::Client->new({server => $hostname});
  $client->debug(1) if 1 < ($opts->verbose || 0);

  $self->add_message(CRITICAL, "$hostname: " . $client->error)
    unless _check_beanstalk($self, $client, $opts);

  $self->nagios_exit($self->check_messages(join => ", "));
  return;
}

sub _check_beanstalk {
  my ($self, $client, $opts) = @_;

  $client->connect or return;

  my @tube = $client->list_tubes or return;

  warn "@tube\n" if $opts->verbose;

  my @opt_tube = @{$opts->get('tube') || []};
  if (@opt_tube) {
    my $v = ($opt_tube[0] =~ /^!/ ? 1 : 0);
    my %tube;
    @tube{@tube} = ($v) x @tube;

    foreach my $opt_tube (@opt_tube) {
      my $v = ($opt_tube =~ s/^!// ? 0 : 1);    # negate
      if ($opt_tube =~ s/^~//) {
        $tube{$_} = $v for grep {/$opt_tube/} keys %tube;
      }
      else {
        $tube{$opt_tube} = $v;
      }
    }
    @tube = grep { $tube{$_} } keys %tube;
  }

  foreach my $tube (@tube) {
    _check_tube($self, $client, $tube) or return;
  }

  return 1;
}

sub _check_tube {
  my ($self, $client, $tube) = @_;

  warn "Checking $tube\n" if $self->opts->verbose;

  $client->use($tube) or return;

  my $age = 0;

  foreach my $i (1 .. 5) {
    if (my $job = $client->peek_ready) {
      my $stats = $job->stats or return;

      # If the job got reserved between the peek ans stats, then try again
      next if $stats->state eq 'reserved';

      $age = $stats->age;
      last;
    }
    elsif ($client->error =~ /NOT_FOUND/) {

      # There are no ready jobs, so all is ok
      last;
    }
    else {
      return;
    }
  }
  $self->add_message($self->check_threshold($age), "tube $tube is $age seconds old");
  $self->add_perfdata(
    label     => $tube,
    value     => $age,
    uom       => 's',
    threshold => $self->threshold
  );
}

__END__

=head1 NAME

Nagios::Plugin::Beanstalk - Nagios plugin to observe Beanstalkd queue server.

=head1 SYNOPSIS

  use Nagios::Plugin::Beanstalk;

  my $np = Nagios::Plugin::Beanstalk->new;
  $np->run;

=head1 DESCRIPTION

Please setup your nagios config.

  ### check response time(msec) for Beanstalk
  define command {
    command_name    check_beanstalkd
    command_line    /usr/bin/check_beanstalkd -H $HOSTADDRESS$ -w 15 -c 60
  }


This plugin can execute with all threshold options together.

=head2 Command Line Options

  Usage: check_beanstalkd -H <host> [-p <port>] [-t <tube>] [-w <warn_time>] [-c <crit_time>]

  Options:
   -h, --help
      Print detailed help screen
   -V, --version
      Print version information
   -H, --hostname=ADDRESS
      Host name, IP Address, or unix socket (must be an absolute path)
   -p, --port=INTEGER
      Port number (default: 389)
   -t [--tube]
      Tube name to watch, can be multiple. 
   -w, --warning=DOUBLE
      Response time to result in warning status (seconds)
   -c, --critical=DOUBLE
      Response time to result in critical status (seconds)
   -v, --verbose
      Show details for command-line debugging (Nagios may truncate output)

=head1 METHODS

=head2 new()

create instance.

=head2 run()

run checks.

=head1 TUBE SELECTION

The argument passed to C<--tube> may be a tube name or a tube pattern
if prefixed with ~. Patterns are applied to the list of tubes that currently
exist on the server

Matching tubes are removed from the list if the argument is prefixed with !

C<--tube> parameters are processed in order. If the first C<--tube> parameter
starts with C<!> then the initial list of tubes to check is all the tubes that
currently exist on the server. If the first C<--tube> parameter does not start
with C<!> then the initial list is empty.

If no C<--tube> parameters are given then all existing tubes are checked

=head2 Examples

=over

=item --tube foo

Only check tube foo

=item --tube !foo

Check all tubes except the tube foo

=item --tube ~foo

Check all tubes that match the pattern /foo/

=item --tube !~foo

Check all tubes except those that match the pattern /foo/

=item --tube ~foo --tube !foobar

Check all tubes that match the pattern /foo/, except foobar

=item --tube !~foo --tube foobar

Check all tubes except those that match the pattern /foo/, but also check foobar

=back

=head1 AUTHOR

Graham Barr C<< <gbarr@pobox.com> >>

=head1 COPYRIGHT & LICENSE

Copyright 2008 Graham Barr

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

