package App::Netdisco::Worker::Plugin::PingSweep;

use Dancer ':syntax';
use App::Netdisco::Worker::Plugin;
use aliased 'App::Netdisco::Worker::Status';

use App::Netdisco::JobQueue 'jq_insert';

use Time::HiRes;
use Sys::SigAction 'timeout_call';
use Net::Ping;
use Net::Ping::External;
use Proc::ProcessTable;
use NetAddr::IP qw/:rfc3021 :lower/;

register_worker({ phase => 'main' }, sub {
  my ($job, $workerconf) = @_;
  my $targets = $job->device
    or return Status->error('missing parameter -d/device with IP prefix');

  my $timeout = $job->extra || '0.1';

  my $net = NetAddr::IP->new($targets);
  if (!$net or $net->num == 0 or $net->addr eq '0.0.0.0') {
      return Status->error(
        sprintf 'unable to understand as host, IP, or prefix: %s', $targets)
  }

  my $job_count = 0;
  my $ping = Net::Ping->new({proto => 'external'});

  my $pinger = sub {
    my $host = shift;
    $ping->ping($host);
    debug sprintf 'pinged %s successfully', $host;
  };

  # this is needed to allow bash/shell subprocess to exit
  $SIG{CHLD} = 'IGNORE';
  # debug sprintf 'I am PID %s', $$;

  ADDRESS: foreach my $idx (0 .. $net->num()) {
    my $addr = $net->nth($idx) or next;
    my $host = $addr->addr;

    if (timeout_call($timeout, $pinger, $host)) {
      debug sprintf 'pinged %s and timed out', $host;

      # this is a bit gross, but needed because Net::Ping::External doesn't
      # provide any cleanup/management or access to child PID
      my $t = Proc::ProcessTable->new;
      foreach my $p ( @{$t->table} ) {
          if ($p->ppid() and $p->ppid() == $$) {
              my $pid = $p->pid();

              foreach my $c ( @{$t->table} ) {
                  if ($c->ppid() and $c->ppid() == $pid) {
                      # debug sprintf 'killing fork %s (%s) of %s', $c->pid(), $c->cmndline(), $p->pid();
                      kill 1, $c->pid();
                  }
              }

              # debug sprintf 'killing fork %s (%s) of %s', $p->pid(), $p->cmndline(), $$;
              kill 1, $p->pid();
          }
      }

      next ADDRESS;
    }

    jq_insert([{
      action => 'discover',
      device => $host,
      username => ($ENV{USER} || 'netdisco-do'),
    }]);

    ++$job_count;
  }

  return Status->done(sprintf
    'Finished ping sweep: queued %s jobs from %s hosts', $job_count, $net->num());
});

true;
