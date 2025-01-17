package Core::Config;
use v5.14;

use parent 'Core::Base';
use Core::Base;

our $config;
our $session_config;
require 'shm.conf';

sub table { return 'config' };

sub structure {
    return {
        key => {
            type => 'key',
        },
        value => {
            type => 'json',
            required => 1,
        },
    }
}

sub table_allow_insert_key { return 1 };

sub validate_attributes {
    my $self = shift;
    my $method = shift;
    my %args = @_;

    my $report = get_service('report');

    unless ( $args{key} || $args{value} ) {
        $report->add_error('KeyOrValueNotPresent');
    }

    if ( $args{key} =~/^_/ ) {
        $report->add_error('KeyProhibited');
    }

    return $report->is_success;
}

sub file {
    my $self = shift;

    return {
        config => $config,
        session => $session_config,
    };
}

sub local {
    my $self = shift;
    my $section = shift;
    my $new_data = shift;

    if ( $new_data ) {
        $self->{config}->{local}->{ $section } = $new_data;
    }

    return $self->{config}->{local} unless $section;
    return $self->{config}->{local}->{ $section };
}

sub data_by_name {
    my $self = shift;
    my %args = (
        key => undef,
        @_,
    );

    my @list = $self->list( where => {
        $args{key} ? ( key => $args{key} ) : (),
    });

    my %ret = map{ $_->{key} => $_->{value} } @list;

    return \%ret;
}

sub delete {
    my $self = shift;
    my %args = @_;

    my $report = get_service('report');

    if ( $self->id =~/^_/ ) {
        $report->add_error('KeyProhibited');
        return undef;
    }

    return $self->SUPER::delete( %args );
}

sub get_data {
    my $self = shift;
    my %args = (
        key => undef,
        @_,
    );

    my $obj = $self;
    if ( $args{key} ) {
        unless ( $obj = $self->id( $args{key} ) ) {
            logger->warning("Config not found");
            get_service('report')->add_error('Config not found');
            return undef;
        }
    }

    my $config = $obj->list(
        where => {
            key => $obj->id,
        }
    );

    return $config->{ $obj->id }->{value};
}

sub list_for_api {
    my $self = shift;
    my %args = (
        key => undef,
        @_,
    );

    return $self->SUPER::list_for_api( where => {
            $args{key} ? ( key => $args{key} ) : (),
    });
}

1;

