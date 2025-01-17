package Core::User;

use v5.14;

use parent 'Core::Base';
use Core::Base;
use Core::Utils qw(
    switch_user
    is_email
    passgen
    now
);
use Core::Const;

use Digest::SHA qw(sha1_hex);
use vars qw($AUTOLOAD);

sub AUTOLOAD {
    my $self = shift;

    if ( $AUTOLOAD =~ /^.*::(get_)?(\w+)$/ ) {
        my $method = $2;

        unless ( my %res = $self->res ) {
            # load data if not loaded before
            $self->get;
        }

        if ( exists $self->res->{ $method } ) {
            return $self->res->{ $method };
        }
        else {
            logger->warning("Field `$method` not exists in structure. User not found?");
            return undef;
        }
    } elsif ( $AUTOLOAD=~/::DESTROY$/ ) {
        # Skip
    } else {
        confess ("Method not exists: " . $AUTOLOAD );
    }
}

sub table { return 'users' };

sub structure {
    return {
        user_id => {
            type => 'key',
        },
        owner => {
            type => 'number',
            hide_for_user => 1,
        },
        login => {
            type => 'text',
            required => 1,
        },
        password => {
            type => 'text',
            required => 1,
            hide_for_user => 1,
        },
        type => {
            type => 'number',
            default => 0,
        },
        created => {
            type => 'now',
        },
        last_login => {
            type => 'date',
        },
        discount => {
            type => 'number',
            default => 0,
        },
        balance => {
            type => 'number',
            default => 0,
        },
        partner => {
            type => 'number',
            default => 0,
        },
        credit => {
            type => 'number',
            default => 0,
        },
        comment => {
            type => 'text',
            hide_for_user => 1,
        },
        dogovor => {
            type => 'text',
        },
        block => {
            type => 'number',
            default => 0,
        },
        partner_disc => {
            type => 'number',
            default => 0,
        },
        gid => {
            type => 'number',
            default => 0,
        },
        perm_credit => {
            type => 'number',
            default => 0,
            hide_for_user => 1,
        },
        full_name => {
            type => 'text',
            allow_update_by_user => 1,
        },
        can_overdraft => {
            type => 'number',
            default => 0,
        },
        bonus => {
            type => 'number',
            default => 0
        },
        phone => {
            type => 'text',
            allow_update_by_user => 1,
        },
        verified => {
            type => 'number',
            default => 0,
        },
        create_act => {
            type => 'number',
            default => 1,
        },
    };
}

sub init {
    my $self = shift;
    my %args = (
        @_,
    );

    unless ( $self->{user_id} ) {
        $self->{user_id} = $self->user_id;
    }

    return $self;
}

sub _id {
    my $self = shift;
    my %args = (
        _id => undef,
        @_,
    );

    my $user_id;
    if ( $args{_id} ) {
        $user_id = $args{_id};
    } elsif ( my $id = $self->get_user_id ) {
        $user_id = $id;
    }

    return $user_id || get_service('config')->local->{user_id};
}

sub authenticated {
    my $self = shift;
    my $config = get_service('config');
    if ( my $user_id = $config->local('authenticated_user_id') ) {
        return get_service('user', _id => $user_id );
    } else {
        return $self;
    }
}

sub events {
    return {
        'payment' => {
            event => {
                title => 'user payment',
                kind => 'UserService',
                method => 'activate_services',
            },
        },
        'user_password_reset' => {
            event => {
                title => 'user password reset',
                kind => 'Transport::Mail',
                method => 'send',
                settings => {
                    template_name => 'user_password_reset',
                },
            },
        },
    };
}

sub crypt_password {
    my $self = shift;
    my %args = (
        salt => undef,
        password => undef,
        @_,
    );

    return sha1_hex( join '--', $args{salt}, $args{password} );
}

sub auth {
    my $self = shift;
    my %args = (
        login => undef,
        password => undef,
        @_,
    );

    return undef unless $args{login} || $args{password};

    my $password = $self->crypt_password(
        salt => $args{login},
        password => $args{password},
    );

    my ( $user_row ) = $self->_list(
        where => {
            login => $args{login},
            password => $password,
        }
    );
    return undef unless $user_row;

    my $user = $self->id( $user_row->{user_id} );
    return undef if $user->is_blocked;

    $user->set( last_login => now );

    return $user;
}

sub passwd {
    my $self = shift;
    my %args = (
        password => undef,
        @_,
    );

    my $report = get_service('report');
    unless ( $args{password} ) {
        $report->add_error('Password is empty');
        return undef;
    }

    my $user = $self;

    if ( $args{admin} && $args{user_id} ) {
        $user = get_service('user', _id => $args{user_id} );
    }

    my $password = $user->crypt_password(
        salt => $user->get_login,
        password => $args{password},
    );

    $user->set( password => $password );
    return scalar $user->get;
}

sub gen_session {
    my $self = shift;
    my %args = (
        usi => undef,
        @_,
    );

    my $session_id = get_service('sessions')->add(
        user_id => $self->id,
        settings => {
            $args{usi} ? ( usi => $args{usi} ) : (),
        },
    );

    return {
        id => $session_id,
    };
}

sub passwd_reset_request {
    my $self = shift;
    my %args = (
        email => undef,
        @_,
    );

    my ( $user ) = $self->_list(
        where => {
            login => $args{email},
        },
    );

    unless ( $user ) {
        # TODO: search in profiles
    }

    if ( $user ) {
        switch_user( $user->{user_id} );
        $self = $self->id( $user->{user_id} );

        if ( $self->is_blocked ) {
            return { msg => 'User is blocked' };
        }

        my $new_password = passgen();
        $self->passwd( password => $new_password );

        $self->make_event( 'user_password_reset',
            settings => {
                new_password => $new_password,
            },
        );
    }

    return { msg => 'Successful' };
}

sub is_blocked {
    my $self = shift;

    return $self->get_block();
}

sub validate_attributes {
    my $self = shift;
    my $method = shift;
    my %args = @_;

    my $report = get_service('report');
    return $report->is_success if $method eq 'set';

    unless ( $args{login} ) {
        $report->add_error('Login is empty');
    }
    unless ( $args{login}=~/^[\w\d@._-]+$/ ) {
        $report->add_error('Login is short or incorrect');
    }

    unless ( $args{password} ) {
        $report->add_error('Password is empty');
    }
    if ( length $args{password} < 6 ) {
        $report->add_error('Password is short');
    }

    return $report->is_success;
}

sub reg {
    my $self = shift;
    my %args = (
        login => undef,
        password => undef,
        @_,
    );

    my $password = $self->crypt_password(
        salt => $args{login},
        password => $args{password},
    );

    my $user_id = $self->add( %args, password => $password );

    unless ( $user_id ) {
        get_service('report')->add_error('Login already exists');
        return undef;
    }

    return scalar get_service( 'user', _id => $user_id )->get;
}

sub services {
    my $self = shift;
    return get_service('UserService', user_id => $self->id );
}

sub set {
    my $self = shift;
    my %args = ( @_ );

    return $self->SUPER::set( %args );
}

sub set_balance {
    my $self = shift;
    my %args = (
        balance => 0,
        credit => 0,
        bonus => 0,
        @_,
    );

    my $data = join(',', map( "$_=$_+?", keys %args ) );
    my $ret = $self->do("UPDATE users SET $data WHERE user_id=?", values %args, $self->id );

    $self->reload() if $ret;

    return $ret;
}

sub payment {
    my $self = shift;
    my %args = (
        money => undef,
        @_,
    );

    unless ( $args{money} ) {
        get_service('report')->add_error("`money` required");
        return undef;
    }

    switch_user( $args{user_id} ) if $args{user_id};

    my $pay_id;
    unless ( $pay_id = get_service('pay')->add( %args ) ) {
        get_service('report')->add_error("Can't make payment");
        return undef;
    }

    get_service('user', $args{user_id} ? ( _id => $args{user_id} ) : ())->set_balance( balance => $args{money} );

    $self->make_event( 'payment' );
    return scalar get_service('pay', _id => $pay_id )->get;
}

sub pays {
    my $self = shift;
    return get_service('pay', user_id => $self->id );
}

sub withdraws {
    my $self = shift;
    return get_service('withdraw', user_id => $self->id );
}

sub is_admin {
    my $self = shift;
    return $self->get_gid;
}

sub list_for_api {
    my $self = shift;
    my %args = (
        admin => 0,
        @_,
    );

    if ( $args{admin} ) {
        $args{where} = { user_id => $args{user_id} } if $args{user_id};
    } else {
        $args{where} = { user_id => $self->id };
    }

    return $self->SUPER::list_for_api( %args );
}

sub profile {
    my $self = shift;

    my $profile = get_service("profile");
    my ( $item ) = $profile->_list(
        where => {
            user_id => $self->id,
        },
        limit => 1,
    );

    return %{ $item->{data} || {} };
}

sub emails {
    my $self = shift;

    my %profile = $self->profile;

    my $email = $profile{email};
    unless ( $email ) {
        if (is_email( $self->get_login)) {
            $email = $self->get_login;
        }
    }
    return $email;
}

1;

