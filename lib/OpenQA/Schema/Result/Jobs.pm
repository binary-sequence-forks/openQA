# Copyright (C) 2015-2020 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, see <http://www.gnu.org/licenses/>.

package OpenQA::Schema::Result::Jobs;

use strict;
use warnings;

use base 'DBIx::Class::Core';

use Try::Tiny;
use Mojo::JSON 'encode_json';
use Fcntl;
use DateTime;
use OpenQA::Utils (
    qw(log_debug log_info log_warning log_error),
    qw(parse_assets_from_settings locate_asset),
    qw(resultdir assetdir read_test_modules find_bugref random_string),
    qw(run_cmd_with_log_return_error needledir testcasedir)
);
use OpenQA::App;
use OpenQA::Jobs::Constants;
use OpenQA::JobDependencies::Constants;
use File::Basename qw(basename dirname);
use File::Spec::Functions 'catfile';
use File::Path ();
use DBIx::Class::Timestamps 'now';
use File::Temp 'tempdir';
use Mojo::File qw(tempfile path);
use Mojo::JSON 'decode_json';
use Data::Dump 'dump';
use Text::Diff;
use OpenQA::File;
use OpenQA::Parser 'parser';
use OpenQA::WebSockets::Client;
# The state and results constants are duplicated in the Python client:
# if you change them or add any, please also update const.py.


# scenario keys w/o MACHINE. Add MACHINE when desired, commonly joined on
# other keys with the '@' character
use constant SCENARIO_KEYS              => (qw(DISTRI VERSION FLAVOR ARCH TEST));
use constant SCENARIO_WITH_MACHINE_KEYS => (SCENARIO_KEYS, 'MACHINE');

__PACKAGE__->table('jobs');
__PACKAGE__->load_components(qw(InflateColumn::DateTime FilterColumn Timestamps));
__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    result_dir => {    # this is the directory below testresults
        data_type   => 'text',
        is_nullable => 1
    },
    state => {
        data_type     => 'varchar',
        default_value => SCHEDULED,
    },
    priority => {
        data_type     => 'integer',
        default_value => 50,
    },
    result => {
        data_type     => 'varchar',
        default_value => NONE,
    },
    reason => {
        data_type   => 'varchar',
        is_nullable => 1,
    },
    clone_id => {
        data_type      => 'integer',
        is_foreign_key => 1,
        is_nullable    => 1
    },
    blocked_by_id => {
        data_type      => 'integer',
        is_foreign_key => 1,
        is_nullable    => 1
    },
    backend => {
        data_type   => 'varchar',
        is_nullable => 1,
    },
    backend_info => {
        # we store free text JSON here - backends might store random data about the job
        data_type   => 'text',
        is_nullable => 1,
    },
    TEST => {
        data_type => 'text'
    },
    DISTRI => {
        data_type     => 'text',
        default_value => ''
    },
    VERSION => {
        data_type     => 'text',
        default_value => ''
    },
    FLAVOR => {
        data_type     => 'text',
        default_value => ''
    },
    ARCH => {
        data_type     => 'text',
        default_value => ''
    },
    BUILD => {
        data_type     => 'text',
        default_value => ''
    },
    MACHINE => {
        data_type   => 'text',
        is_nullable => 1
    },
    group_id => {
        data_type      => 'integer',
        is_foreign_key => 1,
        is_nullable    => 1
    },
    assigned_worker_id => {
        data_type      => 'integer',
        is_foreign_key => 1,
        is_nullable    => 1
    },
    t_started => {
        data_type   => 'timestamp',
        is_nullable => 1,
    },
    t_finished => {
        data_type   => 'timestamp',
        is_nullable => 1,
    },
    logs_present => {
        data_type     => 'boolean',
        default_value => 1,
    },
    passed_module_count => {
        data_type     => 'integer',
        default_value => 0,
    },
    failed_module_count => {
        data_type     => 'integer',
        default_value => 0,
    },
    softfailed_module_count => {
        data_type     => 'integer',
        default_value => 0,
    },
    skipped_module_count => {
        data_type     => 'integer',
        default_value => 0,
    },
    externally_skipped_module_count => {
        data_type     => 'integer',
        default_value => 0,
    },
    scheduled_product_id => {
        data_type      => 'integer',
        is_foreign_key => 1,
        is_nullable    => 1,
    },
    result_size => {
        data_type      => 'integer',
        is_foreign_key => 1,
        is_nullable    => 1,
    },
);
__PACKAGE__->add_timestamps;

__PACKAGE__->set_primary_key('id');
__PACKAGE__->has_many(settings => 'OpenQA::Schema::Result::JobSettings', 'job_id');
__PACKAGE__->has_one(worker => 'OpenQA::Schema::Result::Workers', 'job_id', {cascade_delete => 0});
__PACKAGE__->belongs_to(
    assigned_worker => 'OpenQA::Schema::Result::Workers',
    'assigned_worker_id', {join_type => 'left', on_delete => 'SET NULL'});
__PACKAGE__->belongs_to(
    clone => 'OpenQA::Schema::Result::Jobs',
    'clone_id', {join_type => 'left', on_delete => 'SET NULL'});
__PACKAGE__->belongs_to(
    blocked_by => 'OpenQA::Schema::Result::Jobs',
    'blocked_by_id', {join_type => 'left'});
__PACKAGE__->has_many(
    blocking => 'OpenQA::Schema::Result::Jobs',
    'blocked_by_id'
);
__PACKAGE__->belongs_to(
    group => 'OpenQA::Schema::Result::JobGroups',
    'group_id', {join_type => 'left', on_delete => 'SET NULL'});
__PACKAGE__->might_have(origin => 'OpenQA::Schema::Result::Jobs', 'clone_id', {cascade_delete => 0});
__PACKAGE__->might_have(
    developer_session => 'OpenQA::Schema::Result::DeveloperSessions',
    'job_id', {cascade_delete => 1});
__PACKAGE__->has_many(jobs_assets => 'OpenQA::Schema::Result::JobsAssets', 'job_id');
__PACKAGE__->many_to_many(assets => 'jobs_assets', 'asset');
__PACKAGE__->has_many(last_use_assets => 'OpenQA::Schema::Result::Assets', 'last_use_job_id', {cascade_delete => 0});
__PACKAGE__->has_many(children => 'OpenQA::Schema::Result::JobDependencies', 'parent_job_id');
__PACKAGE__->has_many(parents  => 'OpenQA::Schema::Result::JobDependencies', 'child_job_id');
__PACKAGE__->has_many(
    modules => 'OpenQA::Schema::Result::JobModules',
    'job_id', {cascade_delete => 0, order_by => 'id'});
# Locks
__PACKAGE__->has_many(owned_locks  => 'OpenQA::Schema::Result::JobLocks', 'owner');
__PACKAGE__->has_many(locked_locks => 'OpenQA::Schema::Result::JobLocks', 'locked_by');
__PACKAGE__->has_many(comments     => 'OpenQA::Schema::Result::Comments', 'job_id', {order_by => 'id'});

__PACKAGE__->has_many(networks => 'OpenQA::Schema::Result::JobNetworks', 'job_id');

__PACKAGE__->has_many(gru_dependencies => 'OpenQA::Schema::Result::GruDependencies', 'job_id');
__PACKAGE__->has_many(screenshot_links => 'OpenQA::Schema::Result::ScreenshotLinks', 'job_id');
__PACKAGE__->belongs_to(
    scheduled_product => 'OpenQA::Schema::Result::ScheduledProducts',
    'scheduled_product_id', {join_type => 'left', on_delete => 'SET NULL'});

__PACKAGE__->filter_column(
    result_dir => {
        filter_to_storage   => 'remove_result_dir_prefix',
        filter_from_storage => 'add_result_dir_prefix',
    });

sub sqlt_deploy_hook {
    my ($self, $sqlt_table) = @_;

    $sqlt_table->add_index(name => 'idx_jobs_state',       fields => ['state']);
    $sqlt_table->add_index(name => 'idx_jobs_result',      fields => ['result']);
    $sqlt_table->add_index(name => 'idx_jobs_build_group', fields => [qw(BUILD group_id)]);
    $sqlt_table->add_index(name => 'idx_jobs_scenario',    fields => [qw(VERSION DISTRI FLAVOR TEST MACHINE ARCH)]);
}

# override to straighten out job modules and screenshot references
sub delete {
    my ($self) = @_;

    $self->modules->delete;

    # delete all screenshot references (screenshots left unused are deleted later in the job limit task)
    $self->screenshot_links->delete;

    my $ret = $self->SUPER::delete;

    # last step: remove result directory if already existant
    # This must be executed after $self->SUPER::delete because it might fail and result_dir should not be
    # deleted in the error case
    if ($self->result_dir() && -d $self->result_dir()) {
        File::Path::rmtree($self->result_dir());
    }

    return $ret;
}

sub name {
    my ($self) = @_;
    if (!$self->{_name}) {
        my @a;

        my %formats = (BUILD => 'Build%s',);

        for my $c (qw(DISTRI VERSION FLAVOR ARCH BUILD TEST)) {
            next unless $self->get_column($c);
            push @a, sprintf(($formats{$c} || '%s'), $self->get_column($c));
        }
        my $name = join('-', @a);
        $name .= ('@' . $self->get_column('MACHINE')) if $self->get_column('MACHINE');
        $name =~ s/[^a-zA-Z0-9@._+:-]/_/g;
        $self->{_name} = $name;
    }
    return $self->{_name};
}

sub label {
    my ($self) = @_;

    my $test    = $self->TEST;
    my $machine = $self->MACHINE;
    return $machine ? "$test\@$machine" : $test;
}

sub scenario {
    my ($self) = @_;

    my $test_suite_name = $self->settings_hash->{TEST_SUITE_NAME} || $self->TEST;
    return $self->result_source->schema->resultset('TestSuites')->find({name => $test_suite_name});
}

sub scenario_hash {
    my ($self) = @_;
    my %scenario = map { lc $_ => $self->get_column($_) } SCENARIO_WITH_MACHINE_KEYS;
    return \%scenario;
}

sub scenario_name {
    my ($self) = @_;
    my $scenario = join('-', map { $self->get_column($_) } SCENARIO_KEYS);
    if (my $machine = $self->MACHINE) { $scenario .= "@" . $machine }
    return $scenario;
}

sub scenario_description {
    my ($self) = @_;
    my $description = $self->settings_hash->{JOB_DESCRIPTION};
    return $description if defined $description;
    my $scenario = $self->scenario or return undef;
    return $scenario->description;
}

# return 0 if we have no worker
sub worker_id {
    my ($self) = @_;
    if ($self->worker) {
        return $self->worker->id;
    }
    return 0;
}

sub reschedule_state {
    my $self  = shift;
    my $state = shift // OpenQA::Jobs::Constants::SCHEDULED;

    # cleanup
    $self->set_property('JOBTOKEN');
    $self->release_networks();
    $self->owned_locks->delete;
    $self->locked_locks->update({locked_by => undef});

    $self->update(
        {
            state              => $state,
            t_started          => undef,
            assigned_worker_id => undef,
            result             => NONE
        });

    log_debug('Job ' . $self->id . " reset to state $state");

    # free the worker
    if (my $worker = $self->worker) {
        $self->worker->update({job_id => undef});
    }
}

sub set_assigned_worker {
    my ($self, $worker) = @_;

    my $job_id    = $self->id;
    my $worker_id = $worker->id;
    $self->update(
        {
            state              => ASSIGNED,
            t_started          => undef,
            assigned_worker_id => $worker_id,
        });
    log_debug("Job '$job_id' has worker '$worker_id' assigned");
}

sub prepare_for_work {
    my ($self, $worker, $worker_properties) = @_;
    return undef unless $worker;

    log_debug("[Job#" . $self->id . "] Prepare for being processed by worker " . $worker->id);

    my $job_hashref = {};
    $job_hashref = $self->to_hash(assets => 1);

    # set JOBTOKEN for test access to API
    $worker_properties //= {};
    my $job_token = $worker_properties->{JOBTOKEN} // random_string();
    $worker->set_property(JOBTOKEN => $job_token);
    $job_hashref->{settings}->{JOBTOKEN} = $job_token;

    my $updated_settings = $self->register_assets_from_settings();

    @{$job_hashref->{settings}}{keys %$updated_settings} = values %$updated_settings
      if $updated_settings;

    if (   $job_hashref->{settings}->{NICTYPE}
        && !defined $job_hashref->{settings}->{NICVLAN}
        && $job_hashref->{settings}->{NICTYPE} ne 'user')
    {
        my @networks = ('fixed');
        @networks = split /\s*,\s*/, $job_hashref->{settings}->{NETWORKS} if $job_hashref->{settings}->{NETWORKS};
        my @vlans;
        for my $net (@networks) {
            push @vlans, $self->allocate_network($net);
        }
        $job_hashref->{settings}->{NICVLAN} = join(',', @vlans);
    }

    # TODO: cleanup previous tmpdir
    $worker->set_property(WORKER_TMPDIR => $worker_properties->{WORKER_TMPDIR} // tempdir());

    return $job_hashref;
}

sub ws_send {
    my $self = shift;
    return undef unless my $worker = shift;
    my $hashref = $self->prepare_for_work($worker);
    $hashref->{assigned_worker_id} = $worker->id;
    return OpenQA::WebSockets::Client->singleton->send_job($hashref);
}

sub settings_hash {
    my ($self) = @_;

    if (!defined($self->{_settings})) {
        $self->{_settings} = {};
        for my $var ($self->settings->all()) {
            if (defined $self->{_settings}->{$var->key}) {
                # handle multi-value WORKER_CLASS
                $self->{_settings}->{$var->key} .= ',' . $var->value;
            }
            else {
                $self->{_settings}->{$var->key} = $var->value;
            }
        }
        for my $column (qw(DISTRI VERSION FLAVOR MACHINE ARCH BUILD TEST)) {
            if (my $value = $self->$column) {
                $self->{_settings}->{$column} = $value;
            }
        }
        $self->{_settings}->{NAME} = sprintf "%08d-%s", $self->id, $self->name;
        if ($self->{_settings}->{JOB_TEMPLATE_NAME}) {
            my $test              = $self->{_settings}->{TEST};
            my $job_template_name = $self->{_settings}->{JOB_TEMPLATE_NAME};
            $self->{_settings}->{NAME} =~ s/$test/$job_template_name/e;
        }
    }

    return $self->{_settings};
}

sub deps_hash {
    my ($self) = @_;

    if (!defined($self->{_deps_hash})) {
        my @dependency_names = OpenQA::JobDependencies::Constants::display_names;
        my %parents          = map { $_ => [] } @dependency_names;
        my %children         = map { $_ => [] } @dependency_names;
        $self->{_deps_hash} = {parents => \%parents, children => \%children};
        for my $dep ($self->parents) {
            push @{$parents{$dep->to_string}}, $dep->parent_job_id;
        }
        for my $dep ($self->children) {
            push @{$children{$dep->to_string}}, $dep->child_job_id;
        }
    }

    return $self->{_deps_hash};
}

sub add_result_dir_prefix {
    my ($self, $rd) = @_;

    return catfile($self->num_prefix_dir, $rd) if $rd;
    return;
}

sub remove_result_dir_prefix {
    my ($self, $rd) = @_;
    return basename($rd) if $rd;
    return;
}

sub set_prio {
    my ($self, $prio) = @_;

    $self->update({priority => $prio});
}

sub _hashref {
    my $obj    = shift;
    my @fields = @_;

    my %hashref = ();
    foreach my $field (@fields) {
        my $ref = ref($obj->$field);
        if ($ref =~ /HASH|ARRAY|SCALAR|^$/) {
            $hashref{$field} = $obj->$field;
        }
        elsif ($ref eq 'DateTime') {
            # non standard ref, try to stringify
            $hashref{$field} = $obj->$field->datetime();
        }
        else {
            die "unknown field type: $ref";
        }
    }

    return \%hashref;
}

sub to_hash {
    my ($job, %args) = @_;
    my $j = _hashref($job, qw(id name priority state result clone_id t_started t_finished group_id blocked_by_id));
    if ($j->{group_id}) {
        $j->{group} = $job->group->name;
    }
    if ($job->assigned_worker_id) {
        $j->{assigned_worker_id} = $job->assigned_worker_id;
    }
    if (my $origin = $job->origin) {
        $j->{origin_id} = $origin->id;
    }
    if (my $reason = $job->reason) {
        $j->{reason} = $reason;
    }
    $j->{settings} = $job->settings_hash;
    # hashes are left for script compatibility with schema version 38
    $j->{test} = $job->TEST;
    if ($args{assets}) {
        if (defined $job->{_assets}) {
            for my $asset (@{$job->{_assets}}) {
                push @{$j->{assets}->{$asset->type}}, $asset->name;
            }
        }
        else {
            for my $asset ($job->jobs_assets->all()) {
                push @{$j->{assets}->{$asset->asset->type}}, $asset->asset->name;
            }
        }
    }
    if ($args{deps}) {
        $j = {%$j, %{$job->deps_hash}};
    }
    if ($args{details}) {
        my $test_modules = read_test_modules($job);
        $j->{testresults} = ($test_modules ? $test_modules->{modules} : []);
        $j->{logs}        = $job->test_resultfile_list;
        $j->{ulogs}       = $job->test_uploadlog_list;
    }
    return $j;
}

=head2 can_be_duplicated

=over

=item Arguments: none

=item Return value: 1 if a new clone can be created. undef otherwise.

=back

Checks if a given job can be duplicated - not cloned yet and in correct state.

=cut
sub can_be_duplicated {
    my ($self) = @_;

    my $state = $self->state;
    return unless (grep { /$state/ } (EXECUTION_STATES, FINAL_STATES));
    return if $self->clone;
    return 1;
}

sub missing_assets {
    my ($self) = @_;

    my $assets = parse_assets_from_settings($self->settings_hash);

    # ignore UEFI_PFLASH_VARS; to keep scheduling simple it is present in lots of jobs which actually don't need it
    delete $assets->{UEFI_PFLASH_VARS};

    my @relevant_assets = grep { !OpenQA::Schema::Result::Assets::is_type_hidden($_->{type}) } values %$assets;
    my @assets_query    = map  { {type => $_->{type}, name => $_->{name}} } @relevant_assets;
    my @existing_assets = $self->result_source->schema->resultset('Assets')->search(\@assets_query);
    return [] if scalar @assets_query == scalar @existing_assets;
    my %missing_assets = map { ("$_->{type}/$_->{name}" => 1) } @relevant_assets;
    delete $missing_assets{$_->type . '/' . $_->name} for @existing_assets;
    return [sort keys %missing_assets];
}

=head2 create_clone

=over

=item Arguments: none

=item Return value: new job

=back

Internal function, needs to be executed in a transaction to perform
optimistic locking on clone_id
=cut
sub create_clone {
    my ($self, $prio) = @_;

    # Duplicate settings (except NAME and TEST and JOBTOKEN)
    my @new_settings;
    my $settings = $self->settings;

    while (my $js = $settings->next) {
        unless ($js->key =~ /^(NAME|TEST|JOBTOKEN)$/) {
            push @new_settings, {key => $js->key, value => $js->value};
        }
    }

    my $rset    = $self->result_source->resultset;
    my $new_job = $rset->create(
        {
            TEST     => $self->TEST,
            VERSION  => $self->VERSION,
            ARCH     => $self->ARCH,
            FLAVOR   => $self->FLAVOR,
            MACHINE  => $self->MACHINE,
            BUILD    => $self->BUILD,
            DISTRI   => $self->DISTRI,
            group_id => $self->group_id,
            settings => \@new_settings,
            # assets are re-created in job_grab
            priority => $prio || $self->priority
        });
    # Perform optimistic locking on clone_id. If the job is not longer there
    # or it already has a clone, rollback the transaction (new_job should
    # not be created, somebody else was faster at cloning)
    my $upd = $rset->search({clone_id => undef, id => $self->id})->update({clone_id => $new_job->id});

    # One row affected
    die('There is already a clone!') unless ($upd == 1);

    # Needed to load default values from DB
    $new_job->discard_changes;
    return $new_job;
}

sub create_clones {
    my ($self, $jobs, $prio) = @_;

    my $rset = $self->result_source->resultset;
    my %clones;

    # first create the clones
    for my $job (sort keys %$jobs) {
        my $res = $rset->find($job)->create_clone($prio);
        $clones{$job} = $res;
    }

    # now create dependencies
    for my $job (sort keys %$jobs) {
        my $info = $jobs->{$job};
        my $res  = $clones{$job};

        # recreate dependencies if exists for cloned parents/children
        for my $p (@{$info->{parallel_parents}}) {
            $res->parents->find_or_create(
                {
                    parent_job_id => $clones{$p}->id,
                    dependency    => OpenQA::JobDependencies::Constants::PARALLEL,
                });
        }
        for my $p (@{$info->{chained_parents}}) {
            # normally we don't clone chained parents, but you never know
            $p = $clones{$p}->id if defined $clones{$p};
            $res->parents->find_or_create(
                {
                    parent_job_id => $p,
                    dependency    => OpenQA::JobDependencies::Constants::CHAINED,
                });
        }
        for my $p (@{$info->{directly_chained_parents}}) {
            # be consistent with regularly chained parents regarding cloning
            $p = $clones{$p}->id if defined $clones{$p};
            $res->parents->find_or_create(
                {
                    parent_job_id => $p,
                    dependency    => OpenQA::JobDependencies::Constants::DIRECTLY_CHAINED,
                });
        }
        for my $c (@{$info->{parallel_children}}) {
            $res->children->find_or_create(
                {
                    child_job_id => $clones{$c}->id,
                    dependency   => OpenQA::JobDependencies::Constants::PARALLEL,
                });
        }
        for my $c (@{$info->{chained_children}}) {
            $res->children->find_or_create(
                {
                    child_job_id => $clones{$c}->id,
                    dependency   => OpenQA::JobDependencies::Constants::CHAINED,
                });
        }
        for my $c (@{$info->{directly_chained_children}}) {
            $res->children->find_or_create(
                {
                    child_job_id => $clones{$c}->id,
                    dependency   => OpenQA::JobDependencies::Constants::DIRECTLY_CHAINED,
                });
        }

        # when dependency network is recreated, associate assets
        $res->register_assets_from_settings;
    }

    # calculate blocked_by
    for my $job (keys %$jobs) {
        $clones{$job}->calculate_blocked_by;
    }

    # reduce the clone object to ID (easier to use later on)
    for my $job (keys %$jobs) {
        $jobs->{$job}->{clone} = $clones{$job}->id;
    }
}

# internal (recursive) function for duplicate - returns hash of all jobs in the
# cluster of the current job (in no order but with relations)
sub cluster_jobs {
    my $self = shift;
    my %args = (
        jobs => {},
        # set to 1 when called on a cluster job being cancelled or failing;
        # affects whether we include parallel parents with
        # PARALLEL_CANCEL_WHOLE_CLUSTER set if they have other pending children
        cancelmode => 0,
        @_
    );

    my $jobs = $args{jobs};
    return $jobs if defined $jobs->{$self->id};
    $jobs->{$self->id} = {
        parallel_parents          => [],
        chained_parents           => [],
        directly_chained_parents  => [],
        parallel_children         => [],
        chained_children          => [],
        directly_chained_children => [],
    };

    ## if we have a parallel parent, go up recursively
    my $parents = $self->parents;
  PARENT: while (my $pd = $parents->next) {
        my $p = $pd->parent;

        if ($pd->dependency eq OpenQA::JobDependencies::Constants::CHAINED) {
            push(@{$jobs->{$self->id}->{chained_parents}}, $p->id);
            # we don't duplicate up the chain, only down
            next;
        }
        elsif ($pd->dependency eq OpenQA::JobDependencies::Constants::DIRECTLY_CHAINED) {
            push(@{$jobs->{$self->id}->{directly_chained_parents}}, $p->id);
            # we don't duplicate up the chain, only down
            next;
        }
        elsif ($pd->dependency eq OpenQA::JobDependencies::Constants::PARALLEL) {
            push(@{$jobs->{$self->id}->{parallel_parents}}, $p->id);
            my $cancelwhole = 1;
            # check if the setting to disable cancelwhole is set: the var
            # must exist and be set to something false-y
            my $cwset = $p->settings_hash->{PARALLEL_CANCEL_WHOLE_CLUSTER};
            $cancelwhole = 0 if (defined $cwset && !$cwset);
            if ($args{cancelmode} && !$cancelwhole) {
                # skip calling cluster_jobs (so cancelling it and its other
                # related jobs) if job has pending children we are not
                # cancelling
                my $otherchildren = $p->children;
              CHILD: while (my $childr = $otherchildren->next) {
                    my $child = $childr->child;
                    next CHILD  unless grep { $child->state eq $_ } PENDING_STATES;
                    next PARENT unless $jobs->{$child->id};
                }
            }
            $p->cluster_jobs(jobs => $jobs);
        }
    }

    return $self->cluster_children($jobs);
}

# internal (recursive) function to cluster_jobs
sub cluster_children {
    my ($self, $jobs) = @_;

    my $schema = $self->result_source->schema;

    my $children = $self->children;
    while (my $cd = $children->next) {
        my $c = $cd->child;

        # if this is already cloned, ignore it (mostly chained children)
        next if $c->clone_id;

        # do not fear the recursion
        $c->cluster_jobs(jobs => $jobs);
        my $relation = OpenQA::JobDependencies::Constants::job_info_relation(children => $cd->dependency);
        push(@{$jobs->{$self->id}->{$relation}}, $c->id);
    }
    return $jobs;
}

=head2 duplicate

=over

=item Arguments: optional hash reference containing the key 'prio'

=item Return value: hash of duplicated jobs if duplication suceeded,
                    undef otherwise

=back

Clones the job creating a new one with the same settings and linked through
the 'clone' relationship. This method uses optimistic locking and database
transactions to ensure that only one clone is created per job. If the job
already have a job or the creation fails (most likely due to a concurrent
duplication detected by the optimistic locking), the method returns undef.

Rules for dependencies cloning are:
for PARALLEL dependencies:
- clone parents
 + if parent is clone, find the latest clone and clone it
- clone children
 + if child is clone, find the latest clone and clone it

for CHAINED dependencies:
- do NOT clone parents
 + create new dependency - duplicit cloning is prevented by ignorelist, webui will show multiple chained deps though
- clone children
 + if child is clone, find the latest clone and clone it

=cut
sub duplicate {
    my ($self, $args) = @_;
    $args ||= {};
    my $schema = $self->result_source->schema;

    # If the job already has a clone, none is created
    return unless $self->can_be_duplicated;

    my $jobs = $self->cluster_jobs;
    log_debug("Jobs to duplicate " . dump($jobs));
    try {
        $schema->txn_do(sub { $self->create_clones($jobs, $args->{prio}) });
    }
    catch {
        my $error = shift;
        log_debug("rollback duplicate: $error");
        die "Rollback failed during failed job cloning!"
          if ($error =~ /Rollback failed/);
        $jobs = undef;
    };

    return $jobs;
}

=head2 auto_duplicate

=over

=item Arguments: HASHREF { dup_type_auto => SCALAR }

=item Return value: ID of new job

=back

Handle individual job restart including associated job and asset dependencies. Note that
the caller is responsible to notify the workers about the new job - the model is not doing that.

I.e.
    $job->auto_duplicate;

=cut
sub auto_duplicate {
    my ($self, $args) = @_;
    $args //= {};
    # set this clone was triggered by manually if it's not auto-clone
    $args->{dup_type_auto} //= 0;

    my $job_id = $self->id;
    my $clones = $self->duplicate($args);
    if (!$clones) {
        log_debug("Duplication of job $job_id failed");
        return undef;
    }

    # abort jobs in the old cluster (exclude the original $args->{jobid})
    my $rsource = $self->result_source;
    my $jobs    = $rsource->schema->resultset("Jobs")->search(
        {
            id    => {'!=' => $job_id, '-in' => [keys %$clones]},
            state => [PRE_EXECUTION_STATES, EXECUTION_STATES],
        });

    $jobs->search({result => NONE})->update({result => PARALLEL_RESTARTED});

    while (my $j = $jobs->next) {
        next if $j->abort;
        next unless $j->state eq SCHEDULED || $j->state eq ASSIGNED;
        $j->release_networks;
        $j->update({state => CANCELLED});
    }

    my $clone_id = $clones->{$job_id}->{clone};
    log_debug("Job $job_id duplicated as $clone_id");

    # Attach all clones mapping to new job object
    # TODO: better return a proper hash here
    my $dup = $rsource->resultset->find($clone_id);
    $dup->_cluster_cloned($clones);
    return $dup;
}

sub _cluster_cloned {
    my ($self, $clones) = @_;

    my $cluster_cloned = {};
    for my $c (sort keys %$clones) {
        $cluster_cloned->{$c} = $clones->{$c}->{clone};
    }
    $self->{cluster_cloned} = $cluster_cloned;
}

sub abort {
    my $self   = shift;
    my $worker = $self->worker;
    return 0 unless $worker;

    my ($job_id, $worker_id) = ($self->id, $worker->id);
    log_debug("Sending abort command to worker $worker_id for job $job_id");
    $worker->send_command(command => 'abort', job_id => $job_id);
    return 1;
}

sub scheduler_abort {
    my ($self, $worker) = @_;
    return unless $self->worker || $worker;
    $worker = $self->worker unless $worker;
    log_debug("[Job#" . $self->id . "] Sending scheduler_abort command to worker: " . $worker->id);
    $worker->send_command(command => 'scheduler_abort', job_id => $self->id);
}

sub set_running {
    my $self = shift;

    # avoids to reset the state if e.g. the worker killed the job immediately
    if ($self->state eq ASSIGNED && $self->result eq NONE) {
        $self->update(
            {
                state     => RUNNING,
                t_started => now()});

    }

    if ($self->state eq RUNNING) {
        log_debug("[Job#" . $self->id . "] is in the running state");
        return 1;
    }
    else {
        log_debug(
            "[Job#" . $self->id . "] is already in state '" . $self->state . "' with result '" . $self->result . "'");
        return 0;
    }
}

sub set_property {
    my ($self, $key, $value) = @_;
    my $r = $self->settings->find({key => $key});
    if (defined $value) {
        if ($r) {
            $r->update({value => $value});
        }
        else {
            $self->settings->create(
                {
                    job_id => $self->id,
                    key    => $key,
                    value  => $value
                });
        }
    }
    elsif ($r) {
        $r->delete;
    }
}

# calculate overall result looking at the job modules
sub calculate_result {
    my ($self) = @_;

    my $overall;
    for my $m ($self->modules->all) {
        # this condition might look a bit odd, but the effect is to
        # ensure a job consisting *only* of ignore_failure modules
        # will always result in PASSED, and otherwise, ignore_failure
        # results are basically ignored
        if ($m->result eq PASSED || !$m->important) {
            $overall ||= PASSED;
        }
        elsif ($m->result eq SOFTFAILED) {
            if (!defined $overall || $overall eq PASSED) {
                $overall = SOFTFAILED;
            }
        }
        elsif ($m->result eq SKIPPED) {
            $overall ||= PASSED;
        }
        else {
            $overall = FAILED;
        }
    }

    return $overall || FAILED;
}

sub save_screenshot {
    my ($self, $screen) = @_;
    return unless length($screen->{name});

    my $tmpdir = $self->worker->get_property('WORKER_TMPDIR');
    return unless -d $tmpdir;    # we can't help
    my $current = readlink($tmpdir . "/last.png");
    my $newfile = OpenQA::Utils::save_base64_png($tmpdir, $screen->{name}, $screen->{png});
    unlink($tmpdir . "/last.png");
    symlink("$newfile.png", $tmpdir . "/last.png");
    # remove old file
    unlink($tmpdir . "/$current") if $current;
}

sub append_log {
    my ($self, $log, $file_name) = @_;
    return unless length($log->{data});

    my $path = $self->worker->get_property('WORKER_TMPDIR');
    return unless -d $path;    # we can't help
    $path .= "/$file_name";
    if (open(my $fd, '>>', $path)) {
        print $fd $log->{data};
        close($fd);
    }
    else {
        print STDERR "can't open $path: $!\n";
    }
}

sub update_backend {
    my ($self, $backend_info) = @_;
    $self->update(
        {
            backend      => $backend_info->{backend},
            backend_info => encode_json($backend_info->{backend_info})});
}

sub insert_module {
    my ($self, $tm, $skip_jobs_update) = @_;

    # prepare query to insert job module
    my $insert_sth = $self->{_insert_job_module_sth};
    $insert_sth = $self->{_insert_job_module_sth} = $self->result_source->schema->storage->dbh->prepare(
        <<'END_SQL'
        INSERT INTO job_modules (
            job_id, name, category, script, milestone, important, fatal, always_rollback, t_created, t_updated
        ) VALUES(
            ?,      ?,    ?,        ?,      ?,         ?,         ?,     ?,               now(),      now()
        ) ON CONFLICT DO NOTHING
END_SQL
    ) unless defined $insert_sth;

    # execute query to insert job module
    # note: We have 'important' in the DB but 'ignore_failure' in the flags for historical reasons (see #1266).
    my $flags = $tm->{flags};
    $insert_sth->execute(
        $self->id, $tm->{name}, $tm->{category}, $tm->{script},
        $flags->{milestone}       ? 1 : 0,
        $flags->{ignore_failure}  ? 0 : 1,
        $flags->{fatal}           ? 1 : 0,
        $flags->{always_rollback} ? 1 : 0,
    );
    return 0 unless $insert_sth->rows;

    # update job module statistics for that job (jobs with default result NONE are accounted as skipped)
    $self->update({skipped_module_count => \'skipped_module_count + 1'}) unless $skip_jobs_update;
    return 1;
}

sub insert_test_modules {
    my ($self, $testmodules) = @_;
    return undef unless scalar @$testmodules;

    # insert all test modules and update job module statistics uxing txn to avoid inconsistent job module
    # statistics in the error case
    $self->result_source->schema->txn_do(
        sub {
            my $new_rows = 0;
            $new_rows += $self->insert_module($_, 1) for @$testmodules;
            $self->update({skipped_module_count => \"skipped_module_count + $new_rows"});
        });
}

sub custom_module {
    my ($self, $module, $output) = @_;

    my $parser = parser('Base');
    $parser->include_results(1) if $parser->can("include_results");

    $parser->results->add($module);
    $parser->_add_output($output) if defined $output;

    $self->insert_module($module->test->to_openqa);
    $self->update_module($module->test->name, $module->to_openqa);

    $self->account_result_size($parser->write_output($self->result_dir));
}

sub delete_logs {
    my ($self) = @_;

    my $resultdir = $self->result_dir;
    return unless $resultdir;

    $resultdir .= '/';
    unlink($resultdir . 'autoinst-log.txt');
    unlink($resultdir . 'video.ogv');
    unlink($resultdir . 'serial0.txt');
    unlink($resultdir . 'serial_terminal.txt');
    File::Path::rmtree($resultdir . 'ulogs');

    $self->update({logs_present => 0});
}

sub num_prefix_dir {
    my ($self) = @_;
    my $numprefix = sprintf "%05d", $self->id / 1000;
    return catfile(resultdir(), $numprefix);
}

sub create_result_dir {
    my ($self) = @_;
    my $dir = $self->result_dir();

    if (!$dir) {
        $dir = sprintf "%08d-%s", $self->id, $self->name;
        $dir = substr($dir, 0, 255);
        $self->update({result_dir => $dir});
        $dir = $self->result_dir();
    }
    if (!-d $dir) {
        my $npd = $self->num_prefix_dir;
        mkdir($npd) unless -d $npd;
        my $days = 30;
        $days = $self->group->keep_logs_in_days if $self->group;
        mkdir($dir) || die "can't mkdir $dir: $!";
    }
    my $sdir = $dir . "/.thumbs";
    if (!-d $sdir) {
        mkdir($sdir) || die "can't mkdir $sdir: $!";
    }
    $sdir = $dir . "/ulogs";
    if (!-d $sdir) {
        mkdir($sdir) || die "can't mkdir $sdir: $!";
    }
    return $dir;
}

my %JOB_MODULE_STATISTICS_COLUMN_BY_JOB_MODULE_RESULT = (
    OpenQA::Jobs::Constants::PASSED     => 'passed_module_count',
    OpenQA::Jobs::Constants::SOFTFAILED => 'softfailed_module_count',
    OpenQA::Jobs::Constants::FAILED     => 'failed_module_count',
    OpenQA::Jobs::Constants::NONE       => 'skipped_module_count',
    OpenQA::Jobs::Constants::SKIPPED    => 'externally_skipped_module_count',
);

sub _get_job_module_statistics_column_by_job_module_result {
    my ($job_module_result) = @_;
    return undef unless defined $job_module_result;
    return $JOB_MODULE_STATISTICS_COLUMN_BY_JOB_MODULE_RESULT{$job_module_result};
}

sub update_module {
    my ($self, $name, $raw_result, $known_md5_sums) = @_;

    # find the module
    # note: The name is not strictly unique so use additional query parameters to consistently consider the
    #       most recent module.
    my $mod = $self->modules->find({name => $name}, {order_by => {-desc => 't_updated'}, rows => 1});
    return undef unless $mod;

    # ensure the result dir exists
    $self->create_result_dir;

    # update the result of the job module and update the statistics in the jobs table accordingly
    my $prev_result_column = _get_job_module_statistics_column_by_job_module_result($mod->result);
    my $new_result_column  = _get_job_module_statistics_column_by_job_module_result($mod->update_result($raw_result));
    unless (defined $prev_result_column && defined $new_result_column && $prev_result_column eq $new_result_column) {
        my %job_module_stats_update;
        $job_module_stats_update{$prev_result_column} = \"$prev_result_column - 1" if defined $prev_result_column;
        $job_module_stats_update{$new_result_column}  = \"$new_result_column + 1"  if defined $new_result_column;
        $self->update(\%job_module_stats_update) if %job_module_stats_update;
    }

    $mod->save_details($raw_result->{details}, $known_md5_sums);
}

# computes the progress info for the current job
# important: modules need to be prefetched before in ascending order
sub progress_info {
    my ($self) = @_;
    my @modules = $self->modules->all;

    my $donecount = 0;
    my $modstate  = 'done';
    for my $module (@modules) {
        my $result = $module->result;
        if ($result eq 'running') {
            $modstate = 'current';
        }
        elsif ($modstate eq 'current') {
            $modstate = 'todo';
        }
        elsif ($modstate eq 'done') {
            $donecount++;
        }
    }

    return {
        modcount => int(@modules),
        moddone  => $donecount,
    };
}

sub account_result_size {
    my ($self, $size) = @_;
    $self->update({result_size => \"coalesce(result_size, 0) + $size"});
}

sub store_image {
    my ($self, $asset, $md5, $thumb) = @_;

    my ($storepath, $thumbpath) = OpenQA::Utils::image_md5_filename($md5);
    $storepath = $thumbpath if ($thumb);
    my $prefixdir = dirname($storepath);
    File::Path::make_path($prefixdir);
    $asset->move_to($storepath);
    $self->account_result_size($asset->size);

    if (!$thumb) {
        my $dbpath = OpenQA::Utils::image_md5_filename($md5, 1);
        $self->result_source->schema->resultset('Screenshots')->create_screenshot($dbpath);
        log_debug("store_image: $storepath");
    }
    return $storepath;
}

sub parse_extra_tests {
    my ($self, $asset, $type, $script) = @_;

    return unless ($type eq 'JUnit'
        || $type eq 'XUnit'
        || $type eq 'LTP'
        || $type eq 'IPA');


    local ($@);
    eval {
        my $parser = parser($type);

        $parser->include_results(1) if $parser->can("include_results");
        my $tmp_extra_test = tempfile;

        $asset->move_to($tmp_extra_test);

        $parser->load($tmp_extra_test)->results->each(
            sub {
                return                    if !$_->test;
                $_->test->script($script) if $script;
                my $t_info = $_->test->to_openqa;
                $self->insert_module($t_info);
                $self->update_module($_->test->name, $_->to_openqa);
            });

        $self->account_result_size($parser->write_output($self->result_dir));
    };

    if ($@) {
        log_error("Failed parsing data $type for job " . $self->id . ": " . $@);
        return;
    }
    return 1;
}

sub create_artefact {
    my ($self, $asset, $ulog) = @_;

    my $storepath = $self->create_result_dir();
    return 0 unless $storepath && -d $storepath;

    $storepath .= '/ulogs' if $ulog;
    $asset->move_to(join('/', $storepath, $asset->filename));
    $self->account_result_size($asset->size);
    log_debug("moved to $storepath " . $asset->filename);
    return 1;
}

sub create_asset {
    my ($self, $asset, $scope) = @_;

    my $fname = $asset->filename;

    # FIXME: pass as parameter to avoid guessing
    my $type;
    $type = 'iso' if $fname =~ /\.iso$/;
    $type = 'hdd' if $fname =~ /\.(?:qcow2|raw|vhd|vhdx)$/;
    $type //= 'other';

    $fname = sprintf("%08d-%s", $self->id, $fname) if $scope ne 'public';

    my $assetdir  = assetdir();
    my $fpath     = path($assetdir, $type);
    my $temp_path = path($assetdir, 'tmp', $scope);

    my $temp_chunk_folder = path($temp_path,         join('.', $fname, 'CHUNKS'));
    my $temp_final_file   = path($temp_chunk_folder, $fname);
    my $final_file        = path($fpath,             $fname);

    $fpath->make_path             unless -d $fpath;
    $temp_path->make_path         unless -d $temp_path;
    $temp_chunk_folder->make_path unless -d $temp_chunk_folder;

    # XXX : Moving this to subprocess/promises won't help much
    # As calculating sha256 over >2GB file is pretty expensive
    # IF we are receiving simultaneously uploads
    my $last = 0;

    local $@;
    eval {
        my $chunk = OpenQA::File->deserialize($asset->slurp);
        $chunk->decode_content;
        $chunk->write_content($temp_final_file);

        # Always checking written data SHA
        unless ($chunk->verify_content($temp_final_file)) {
            $temp_chunk_folder->remove_tree if ($chunk->is_last);
            die Mojo::Exception->new("Can't verify written data from chunk");
        }

        if ($chunk->is_last) {
            # XXX: Watch out also apparmor permissions
            my $sum;
            my $real_sum;
            $last++;

            # Perform weak check on last bytes if files > 250MB
            if ($chunk->end > 250000000) {
                $sum      = $chunk->end;
                $real_sum = -s $temp_final_file->to_string;
            }
            else {
                $sum      = $chunk->total_cksum;
                $real_sum = $chunk->file_digest($temp_final_file->to_string);
            }

            $temp_chunk_folder->remove_tree
              && die Mojo::Exception->new("Checksum mismatch expected $sum got: $real_sum ( weak check on last bytes )")
              unless $sum eq $real_sum;

            $temp_final_file->move_to($final_file);

            chmod 0644, $final_file;

            $temp_chunk_folder->remove_tree;
        }
        $chunk->content(\undef);
    };
    # $temp_chunk_folder->remove_tree if $@; # XXX: Don't! as worker will try again to upload.
    return $@ if $@;
    return 0, $fname, $type, $last;
}

sub has_failed_modules {
    my ($self) = @_;
    return $self->modules->count({result => 'failed'}, {rows => 1});
}

sub failed_modules {
    my ($self) = @_;

    my $fails = $self->modules->search({result => 'failed'}, {order_by => 't_updated'});
    my @failedmodules;

    while (my $module = $fails->next) {
        push(@failedmodules, $module->name);
    }
    return \@failedmodules;
}

sub update_status {
    my ($self, $status) = @_;
    my $ret = {result => 1};

    # that is a bit of an abuse as we don't have anything of the
    # other payload
    if ($status->{uploading}) {
        $self->update({state => UPLOADING});
        return $ret;
    }

    $self->append_log($status->{log},             "autoinst-log-live.txt");
    $self->append_log($status->{serial_log},      "serial-terminal-live.txt");
    $self->append_log($status->{serial_terminal}, "serial-terminal-live.txt");
    # delete from the hash so it becomes dumpable for debugging
    my $screen = delete $status->{screen};
    $self->save_screenshot($screen)                   if $screen;
    $self->update_backend($status->{backend})         if $status->{backend};
    $self->insert_test_modules($status->{test_order}) if $status->{test_order};
    my %known;
    if (my $result = $status->{result}) {
        for my $name (sort keys %$result) {
            $self->update_module($name, $result->{$name}, \%known);
        }
    }
    $ret->{known_images} = [sort keys %known];

    # update info used to compose the URL to os-autoinst command server
    if (my $assigned_worker = $self->assigned_worker) {
        $assigned_worker->set_property(CMD_SRV_URL     => ($status->{cmd_srv_url}     // ''));
        $assigned_worker->set_property(WORKER_HOSTNAME => ($status->{worker_hostname} // ''));
    }

    $self->state(RUNNING) and $self->t_started(now()) if grep { $_ eq $self->state } (ASSIGNED, SETUP);
    $self->update();

    # result=1 for the call, job_result for the current state
    $ret->{job_result} = $self->calculate_result();

    return $ret;
}

sub register_assets_from_settings {
    my ($self) = @_;
    my $settings = $self->settings_hash;

    my %assets = %{parse_assets_from_settings($settings)};

    return unless keys %assets;

    my @parents_rs = $self->parents->search(
        {
            dependency => OpenQA::JobDependencies::Constants::CHAINED,
        },
        {
            columns => ['parent_job_id'],
        });
    my @parents = map { $_->parent_job_id } @parents_rs;

    # updated settings with actual file names
    my %updated;

    # check assets and fix the file names
    for my $k (keys %assets) {
        my $asset = $assets{$k};
        my ($name, $type) = ($asset->{name}, $asset->{type});
        unless ($name && $type) {
            log_info 'not registering asset with empty name or type';
            delete $assets{$k};
            next;
        }
        if ($name =~ /\//) {
            log_info "not registering asset $name containing /";
            delete $assets{$k};
            next;
        }
        my $f_asset = _asset_find($name, $type, \@parents);
        unless (defined $f_asset) {
            # don't register asset not yet available
            delete $assets{$k};
            next;
        }
        $asset->{name} = $f_asset;
        $updated{$k} = $f_asset;
    }

    for my $asset (values %assets) {
        # avoid plain create or we will get unique constraint problems
        # in case ISO_1 and ISO_2 point to the same ISO
        my $aid = $self->result_source->schema->resultset('Assets')->find_or_create($asset);
        $self->jobs_assets->find_or_create({asset_id => $aid->id});
    }

    return \%updated;
}

sub _asset_find {
    my ($name, $type, $parents) = @_;

    # add undef to parents so that we check regular assets too
    for my $parent (@$parents, undef) {
        my $fname = $parent ? sprintf("%08d-%s", $parent, $name) : $name;
        return $fname if (locate_asset($type, $fname, mustexist => 1));
    }
    return;
}

sub allocate_network {
    my ($self, $name) = @_;

    my $vlan = $self->_find_network($name);
    return $vlan if $vlan;
    #allocate new
    my @used_rs = $self->result_source->schema->resultset('JobNetworks')->search(
        {},
        {
            columns  => ['vlan'],
            group_by => ['vlan'],
        });
    my %used = map { $_->vlan => 1 } @used_rs;

    for ($vlan = 1;; $vlan++) {
        next if ($used{$vlan});
        my $created;
        # a transaction is needed to avoid the same tag being assigned
        # to two jobs that requires a new vlan tag in the same time.
        try {
            $self->networks->result_source->schema->txn_do(
                sub {
                    my $found = $self->networks->find_or_new({name => $name, vlan => $vlan});
                    unless ($found->in_storage) {
                        $found->insert;
                        log_debug("Created network for " . $self->id . " : $vlan");
                        # return the vlan tag only if we are sure it is in the DB
                        $created = 1 if ($found->in_storage);
                    }
                });
        }
        catch {
            log_debug("Failed to create new vlan tag: $vlan");    # uncoverable statement
            next;                                                 # uncoverable statement
        };
        if ($created) {
            # mark it for the whole cluster - so that the vlan only appears
            # if all of the cluster is gone.
            for my $cj (keys %{$self->cluster_jobs}) {
                next if $cj == $self->id;
                $self->result_source->schema->resultset('JobNetworks')
                  ->create({name => $name, vlan => $vlan, job_id => $cj});
            }

            return $vlan;
        }
    }
}

sub _find_network {
    my ($self, $name, $seen) = @_;

    $seen //= {};

    return if $seen->{$self->id};
    $seen->{$self->id} = 1;

    my $net = $self->networks->find({name => $name});
    return $net->vlan if $net;

    my $parents = $self->parents->search(
        {
            dependency => OpenQA::JobDependencies::Constants::PARALLEL,
        });
    while (my $pd = $parents->next) {
        my $vlan = $pd->parent->_find_network($name, $seen);
        return $vlan if $vlan;
    }

    my $children = $self->children->search(
        {
            dependency => OpenQA::JobDependencies::Constants::PARALLEL,
        });
    while (my $cd = $children->next) {
        my $vlan = $cd->child->_find_network($name, $seen);
        return $vlan if $vlan;
    }
}

sub release_networks {
    my ($self) = @_;

    $self->networks->delete;
}

sub needle_dir() {
    my ($self) = @_;
    unless ($self->{_needle_dir}) {
        my $distri  = $self->DISTRI;
        my $version = $self->VERSION;
        $self->{_needle_dir} = OpenQA::Utils::needledir($distri, $version);
    }
    return $self->{_needle_dir};
}

# return the last X complete jobs of the same scenario
sub _previous_scenario_jobs {
    my ($self, $rows) = @_;

    my $schema = $self->result_source->schema;
    my $conds  = [{'me.state' => 'done'}, {'me.result' => [COMPLETE_RESULTS]}, {'me.id' => {'<', $self->id}}];
    for my $key (SCENARIO_WITH_MACHINE_KEYS) {
        push(@$conds, {"me.$key" => $self->get_column($key)});
    }
    my %attrs = (
        order_by => ['me.id DESC'],
        rows     => $rows
    );
    return $schema->resultset("Jobs")->search({-and => $conds}, \%attrs)->all;
}

# internal function to compare two failure reasons
sub _failure_reason {
    my ($self) = @_;

    my @failed_modules;
    my $modules = $self->modules;

    while (my $m = $modules->next) {
        if ($m->result eq FAILED || $m->result eq SOFTFAILED) {
            # Look for serial failures which have bug reference
            my @bugrefs = map { find_bugref($_->{title}) || '' } @{$m->details->{results}};
            # If bug reference is in title, put it as a failure reason, otherwise use module name
            if (my $failure_reason = join('', @bugrefs)) {
                return $failure_reason;
            }
            push(@failed_modules, $m->name . ':' . $m->result);
        }
    }

    if (@failed_modules) {
        return join(',', @failed_modules) || $self->result;
    }
    # No failed modules found
    return 'GOOD';
}

sub _carry_over_candidate {
    my ($self) = @_;

    my $current_failure_reason = $self->_failure_reason;
    my $prev_failure_reason    = '';
    my $state_changes          = 0;
    my $lookup_depth           = 10;
    my $state_changes_limit    = 3;

    # we only do carryover for jobs with some kind of (soft) failure
    return if $current_failure_reason eq 'GOOD';

    # search for previous jobs
    for my $job ($self->_previous_scenario_jobs($lookup_depth)) {
        my $job_fr = $job->_failure_reason;
        log_debug(sprintf("checking take over from %d: %s vs %s", $job->id, $job_fr, $current_failure_reason));
        if ($job_fr eq $current_failure_reason) {
            log_debug("found a good candidate");
            return $job;
        }

        if ($job_fr eq $prev_failure_reason) {
            log_debug("ignoring job with repeated problem");
            next;
        }

        $prev_failure_reason = $job_fr;
        $state_changes++;

        # if the job changed failures more often, we assume
        # that the carry over is pointless
        if ($state_changes > $state_changes_limit) {
            log_debug("changed state more than $state_changes_limit, aborting search");
            return;
        }
    }
    return;
}

=head2 carry_over_bugrefs

carry over bugrefs (i.e. special comments) from previous jobs to current
result in the same scenario.

=cut
sub carry_over_bugrefs {
    my ($self) = @_;

    if (my $group = $self->group) {
        return unless $group->carry_over_bugrefs;
    }

    my $prev = $self->_carry_over_candidate;
    return if !$prev;

    my $comments = $prev->comments->search({}, {order_by => {-desc => 'me.id'}});

    while (my $comment = $comments->next) {
        next if !($comment->bugref);

        my $text = $comment->text;
        if ($text !~ "Automatic takeover") {
            $text .= "\n\n(Automatic takeover from t#" . $prev->id . ")\n";
        }
        my %newone = (text => $text);
        # TODO can we also use another user id to tell that
        # this comment was created automatically and not by a
        # human user?
        $newone{user_id} = $comment->user_id;
        $self->comments->create(\%newone);
        last;
    }
    return;
}

sub bugref {
    my ($self) = @_;

    my $comments = $self->comments->search({}, {order_by => {-desc => 'me.id'}});
    while (my $comment = $comments->next) {
        if (my $bugref = $comment->bugref) {
            return $bugref;
        }
    }
    return undef;
}

# extend to finish
sub store_column {
    my ($self, %args) = @_;
    if ($args{state} && grep { $args{state} eq $_ } FINAL_STATES) {
        if (!$self->t_finished) {
            # make sure we do not overwrite a t_finished from fixtures
            # in normal operation it should be impossible to finish
            # twice
            $self->t_finished(now());
        }
        # make sure no modules are left running
        $self->modules->search({result => RUNNING})->update({result => NONE});
    }
    return $self->SUPER::store_column(%args);
}

# used to stop jobs with some kind of dependency relationship to another
# job that failed or was cancelled, see cluster_jobs(), cancel() and done()
sub _job_stop_cluster {
    my ($self, $job) = @_;

    # skip ourselves
    return 0 if $job == $self->id;
    my $rset = $self->result_source->resultset;

    $job = $rset->search({id => $job, result => NONE})->first;
    return 0 unless $job;

    if ($job->state eq SCHEDULED || $job->state eq ASSIGNED) {
        $job->release_networks;
        $job->update({result => SKIPPED, state => CANCELLED});
    }
    else {
        $job->update({result => PARALLEL_FAILED});
    }
    if (my $worker = $job->assigned_worker) {
        $worker->send_command(command => 'cancel', job_id => $job->id);
    }

    return 1;
}

sub test_uploadlog_list {
    # get a list of uploaded logs
    my ($self) = @_;
    return [] unless my $testresdir = $self->result_dir();

    my @filelist;
    for my $f (glob "$testresdir/ulogs/*") {
        $f =~ s#.*/##;
        push(@filelist, $f);
    }
    return \@filelist;
}

sub test_resultfile_list {
    # get a list of existing resultfiles
    my ($self) = @_;
    return [] unless my $testresdir = $self->result_dir();

    my @filelist = qw(video.ogv vars.json backend.json serial0.txt autoinst-log.txt worker-log.txt);
    my @filelist_existing;
    for my $f (@filelist) {
        if (-e "$testresdir/$f") {
            push(@filelist_existing, $f);
        }
    }

    for my $f (qw(serial_terminal.txt)) {
        if (-s "$testresdir/$f") {
            push(@filelist_existing, $f);
        }
    }

    for (my $i = 1; $i < ($self->settings_hash->{VIRTIO_CONSOLE_NUM} // 1); $i++) {
        if (-s "$testresdir/virtio_console$i.log") {
            push(@filelist_existing, "virtio_console$i.log");
        }
    }

    return \@filelist_existing;
}

sub git_log_diff {
    my ($self, $dir, $refspec_range) = @_;
    my $res = run_cmd_with_log_return_error(
        ['git', '-C', $dir, 'log', '--pretty=oneline', '--abbrev-commit', '--no-merges', $refspec_range]);
    # regardless of success or not the output contains the information we need
    return "\n" . $res->{stderr} if $res->{stderr};
}

sub git_diff {
    my ($self, $dir, $refspec_range) = @_;
    my $res = run_cmd_with_log_return_error(['git', '-C', $dir, 'diff', '--stat', $refspec_range]);
    return "\n" . $res->{stderr} if $res->{stderr};
}

=head2 investigate

Find pointers for investigation on failures, e.g. what changed vs. a "last
good" job in the same scenario.

=cut
sub investigate {
    my ($self, %args) = @_;
    my @previous = $self->_previous_scenario_jobs;
    return {error => 'No previous job in this scenario, cannot provide hints'} unless @previous;
    my %inv;
    return {error => 'No result directory available for current job'} unless $self->result_dir();
    my $ignore = OpenQA::App->singleton->config->{global}->{job_investigate_ignore};
    for my $prev (@previous) {
        next unless $prev->result =~ /(?:passed|softfailed)/;
        $inv{last_good} = $prev->id;
        last unless $prev->result_dir;
        # just ignore any problems on generating the diff with eval, e.g.
        # files missing. This is a best-effort approach.
        my @files = map { Mojo::File->new($_->result_dir(), 'vars.json')->slurp } ($prev, $self);
        my $diff  = eval { diff(\$files[0], \$files[1], {CONTEXT => 0}) };
        $inv{diff_to_last_good} = join("\n", grep { !/(^@@|$ignore)/ } split(/\n/, $diff));
        my ($before, $after) = map { decode_json($_) } @files;
        my $dir           = testcasedir($self->DISTRI, $self->VERSION);
        my $refspec_range = "$before->{TEST_GIT_HASH}..$after->{TEST_GIT_HASH}";
        $inv{test_log} = $self->git_log_diff($dir, $refspec_range);
        $inv{test_log} ||= 'No test changes recorded, test regression unlikely';
        $inv{test_diff_stat} = $self->git_diff($dir, $refspec_range) if $inv{test_log};
        # no need for duplicating needles git log if the git repo is the same
        # as for tests
        if ($after->{TEST_GIT_HASH} ne $after->{NEEDLES_GIT_HASH}) {
            $dir = needledir($self->DISTRI, $self->VERSION);
            my $refspec_needles_range = "$before->{NEEDLES_GIT_HASH}..$after->{NEEDLES_GIT_HASH}";
            $inv{needles_log} = $self->git_log_diff($dir, $refspec_needles_range);
            $inv{needles_log} ||= 'No needle changes recorded, test regression due to needles unlikely';
            $inv{needles_diff_stat} = $self->git_diff($dir, $refspec_needles_range) if $inv{needles_log};
        }
        last;
    }
    $inv{last_good} //= 'not found';
    return \%inv;
}

=head2 done

Finalize job by setting it as DONE.

Accepted optional arguments:
  newbuild => 0/1
  result   => see RESULTS

newbuild set marks build as OBSOLETED
if result is not set (expected default situation) result is computed from the results of individual
test modules

=cut
sub done {
    my ($self, %args) = @_;
    $args{result} = OBSOLETED if $args{newbuild};

    # cleanup
    $self->set_property('JOBTOKEN');
    $self->release_networks();
    $self->owned_locks->delete;
    $self->locked_locks->update({locked_by => undef});
    if (my $worker = $self->worker) {
        # free the worker
        $worker->update({job_id => undef});
    }

    # update result unless already known (it is already known for CANCELLED jobs)
    # update the reason if updating the result or if there is no reason yet
    my $result         = lc($args{result} || $self->calculate_result);
    my $reason         = $args{reason};
    my $result_unknown = $self->result eq NONE;
    my $reason_unknown = !$self->reason;
    my %new_val        = (state => DONE);
    $new_val{result} = $result if $result_unknown;
    $new_val{reason} = $reason if ($result_unknown || $reason_unknown) && defined $reason;
    $self->update(\%new_val);

    # stop other jobs in the cluster
    if (defined $new_val{result} && !grep { $result eq $_ } OK_RESULTS) {
        my $jobs = $self->cluster_jobs(cancelmode => 1);
        for my $job (sort keys %$jobs) {
            $self->_job_stop_cluster($job);
        }
    }

    # bugrefs are there to mark reasons of failure - the function checks itself though
    $self->carry_over_bugrefs;
    $self->unblock;

    return $result;
}

sub cancel {
    my ($self, $obsoleted) = @_;
    $obsoleted //= 0;
    my $result = $obsoleted ? OBSOLETED : USER_CANCELLED;
    return if ($self->result ne NONE);
    my $state = $self->state;
    $self->release_networks;
    $self->update(
        {
            state  => CANCELLED,
            result => $result
        });

    my $count = 1;
    if (my $worker = $self->assigned_worker) {
        $worker->send_command(command => 'cancel', job_id => $self->id);
    }
    my $jobs = $self->cluster_jobs(cancelmode => 1);
    for my $job (sort keys %$jobs) {
        $count += $self->_job_stop_cluster($job);
    }

    return $count;
}

sub dependencies {
    my ($self) = @_;

    my @dependency_names = OpenQA::JobDependencies::Constants::display_names;
    my %parents          = map { $_ => [] } @dependency_names;
    my %children         = map { $_ => [] } @dependency_names;

    my $jp = $self->parents;
    while (my $s = $jp->next) {
        push(@{$parents{$s->to_string}}, $s->parent_job_id);
    }
    my $jc = $self->children;
    while (my $s = $jc->next) {
        push(@{$children{$s->to_string}}, $s->child_job_id);
    }

    return {
        parents  => \%parents,
        children => \%children
    };
}

sub result_stats {
    my ($self) = @_;

    return {
        passed     => $self->passed_module_count,
        softfailed => $self->softfailed_module_count,
        failed     => $self->failed_module_count,
        none       => $self->skipped_module_count,
        skipped    => $self->externally_skipped_module_count,
    };
}

sub blocked_by_parent_job {
    my ($self) = @_;

    my $cluster_jobs = $self->cluster_jobs;

    my $job_info              = $cluster_jobs->{$self->id};
    my @possibly_blocked_jobs = ($self->id, @{$job_info->{parallel_parents}}, @{$job_info->{parallel_children}});

    my $chained_parents = $self->result_source->schema->resultset('JobDependencies')->search(
        {
            dependency   => {-in => [OpenQA::JobDependencies::Constants::CHAINED_DEPENDENCIES]},
            child_job_id => {-in => \@possibly_blocked_jobs}
        },
        {order_by => ['parent_job_id', 'child_job_id']});

    while (my $pd = $chained_parents->next) {
        my $p     = $pd->parent;
        my $state = $p->state;

        next if (grep { /$state/ } FINAL_STATES);
        return $p->id;
    }
    return undef;
}

sub calculate_blocked_by {
    my ($self) = @_;
    $self->update({blocked_by_id => $self->blocked_by_parent_job});
}

sub unblock {
    my ($self) = @_;

    for my $j ($self->blocking) {
        $j->calculate_blocked_by;
    }
}

sub has_dependencies {
    my ($self) = @_;

    my $id           = $self->id;
    my $dependencies = $self->result_source->schema->resultset('JobDependencies');
    return $dependencies->search({-or => {child_job_id => $id, parent_job_id => $id}}, {rows => 1})->count;
}

sub status {
    my ($self) = @_;

    my $state      = $self->state;
    my $meta_state = OpenQA::Jobs::Constants::meta_state($state);
    return OpenQA::Jobs::Constants::meta_result($self->result) if $meta_state eq OpenQA::Jobs::Constants::FINAL;
    return (defined $self->blocked_by_id ? 'blocked' : $state) if $meta_state eq OpenQA::Jobs::Constants::PRE_EXECUTION;
    return $meta_state;
}

sub status_info {
    my ($self) = @_;

    my $info = $self->state;
    $info .= ' with result ' . $self->result if grep { $info eq $_ } FINAL_STATES;
    return $info;
}

sub overview_result {
    my ($self, $job_labels, $aggregated, $failed_modules, $todo) = @_;

    my $jobid = $self->id;
    if ($self->state eq OpenQA::Jobs::Constants::DONE) {
        my $actually_failed_modules = $self->failed_modules;
        return undef
          unless !$failed_modules
          || OpenQA::Utils::any_array_item_contained_by_hash($actually_failed_modules, $failed_modules);

        my $result_stats = $self->result_stats;
        my $overall      = $self->result;

        if ($todo) {
            # skip all jobs NOT needed to be labeled for the black certificate icon to show up
            return undef
              if $self->result eq OpenQA::Jobs::Constants::PASSED
              || $job_labels->{$jobid}{bugs}
              || $job_labels->{$jobid}{label}
              || ($self->result eq OpenQA::Jobs::Constants::SOFTFAILED
                && ($job_labels->{$jobid}{label} || !$self->has_failed_modules));
        }

        $aggregated->{OpenQA::Jobs::Constants::meta_result($overall)}++;
        return {
            passed     => $result_stats->{passed},
            unknown    => $result_stats->{none},
            failed     => $result_stats->{failed},
            overall    => $overall,
            jobid      => $jobid,
            state      => OpenQA::Jobs::Constants::DONE,
            failures   => $actually_failed_modules,
            bugs       => $job_labels->{$jobid}{bugs},
            bugdetails => $job_labels->{$jobid}{bugdetails},
            label      => $job_labels->{$jobid}{label},
            comments   => $job_labels->{$jobid}{comments},
        };
    }
    elsif ($self->state eq OpenQA::Jobs::Constants::RUNNING) {
        return undef if $todo;
        $aggregated->{running}++;
        return {
            state => OpenQA::Jobs::Constants::RUNNING,
            jobid => $jobid,
        };
    }
    else {
        return undef if $todo;
        my $result = {
            state    => $self->state,
            jobid    => $jobid,
            priority => $self->priority,
        };
        if ($self->state eq OpenQA::Jobs::Constants::SCHEDULED) {
            $aggregated->{scheduled}++;
            $result->{blocked} = 1 if defined $self->blocked_by_id;
        }
        else {
            $aggregated->{none}++;
        }
        return $result;
    }
}

1;

