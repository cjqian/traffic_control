package API::DeliveryService;
#
# Copyright 2015 Comcast Cable Communications Management, LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
#
#

# JvD Note: you always want to put Utils as the first use. Sh*t don't work if it's after the Mojo lines.
use UI::Utils;
use Mojo::Base 'Mojolicious::Controller';
use Data::Dumper;
use POSIX qw(strftime);
use Utils::Helper::Datasource;
use Time::HiRes qw(gettimeofday tv_interval);
use Math::Round qw(nearest);

my $valid_server_types = {
	edge => "EDGE",
	mid  => "MID",
};

# this structure maps the above types to the allowed metrics below
my $valid_metric_types = {
	origin_tps => "mid",
	ooff       => "mid",
};

sub delivery_services {
	my $self = shift;
	my $id   = $self->param('id');

	my $helper = new Utils::Helper( { mojo => $self } );
	if ( defined($id) && $helper->is_valid_delivery_service($id) ) {
		if ( $helper->is_delivery_service_assigned($id) || &is_oper($self) ) {
			return $self->get_data();
		}
		else {
			return $self->forbidden();
		}
	}
	if ( defined($id) && !$helper->is_valid_delivery_service($id) ) {
		return $self->not_found();
	}
	else {
		return $self->get_data();
	}
}

sub get_data {
	my $self = shift;
	my $id   = $self->param('id');
	my @data;
	my $portal_role = $self->db->resultset('Role')->search( { name => 'portal' } )->get_column('id')->single();
	my $tm_user    = $self->db->resultset('TmUser')->search( { username => $self->current_user()->{username} } )->single();
	my $tm_user_id = $tm_user->id;
	my @ds_ids     = ();

	if ( defined($tm_user_id) && $tm_user->role->id eq $portal_role ) {
		@ds_ids = $self->db->resultset('DeliveryserviceTmuser')->search( { tm_user_id => $tm_user_id } )->get_column('deliveryservice')->all();
	}
	else {
		@ds_ids = $self->db->resultset('Deliveryservice')->search(undef)->get_column('id')->all();
	}
	my %ds_hash = map { $_ => 1 } @ds_ids;
	my $rs;
	if ( defined($id) ) {
		$rs = $self->db->resultset("Deliveryservice")->search( { id => $id }, { prefetch => ['deliveryservice_regexes'] } );
	}
	else {
		$rs = $self->db->resultset("Deliveryservice")->search( undef, { prefetch => ['deliveryservice_regexes'], order_by => 'xml_id' } );
	}
	while ( my $row = $rs->next ) {
		next if ( defined($tm_user_id) && !defined( $ds_hash{ $row->id } ) );
		my $re_rs     = $row->deliveryservice_regexes;
		my @matchlist = ();
		while ( my $re_row = $re_rs->next ) {
			push(
				@matchlist, {
					type      => $re_row->regex->type->name,
					pattern   => $re_row->regex->pattern,
					setNumber => $re_row->set_number,
				}
			);
		}
		push(
			@data, {
				"id"                   => $row->id,
				"xmlId"                => $row->xml_id,
				"dscp"                 => $row->dscp,
				"signed"               => \$row->signed,
				"qstringIgnore"        => $row->qstring_ignore,
				"geoLimit"             => $row->geo_limit,
				"httpBypassFqdn"       => $row->http_bypass_fqdn,
				"dnsBypassIp"          => $row->dns_bypass_ip,
				"dnsBypassIp6"         => $row->dns_bypass_ip6,
				"dnsBypassTtl"         => $row->dns_bypass_ttl,
				"orgServerFqdn"        => $row->org_server_fqdn,
				"ccrDnsTtl"            => $row->ccr_dns_ttl,
				"type"                 => $row->type->name,
				"profileName"          => $row->profile->name,
				"profileDescription"   => $row->profile->description,
				"globalMaxMbps"        => $row->global_max_mbps,
				"globalMaxTps"         => $row->global_max_tps,
				"headerRewrite"        => $row->edge_header_rewrite,
				"edgeHeaderRewrite"    => $row->edge_header_rewrite,
				"midHeaderRewrite"     => $row->mid_header_rewrite,
				"regexRemap"           => $row->regex_remap,
				"longDesc"             => $row->long_desc,
				"longDesc1"            => $row->long_desc_1,
				"longDesc2"            => $row->long_desc_2,
				"maxDnsAnswers"        => $row->max_dns_answers,
				"infoUrl"              => $row->info_url,
				"missLat"              => $row->miss_lat,
				"missLong"             => $row->miss_long,
				"checkPath"            => $row->check_path,
				"matchList"            => \@matchlist,
				"active"               => \$row->active,
				"protocol"             => $row->protocol,
				"ipv6RoutingEnabled"   => \$row->ipv6_routing_enabled,
				"rangeRequestHandling" => $row->range_request_handling,
				"cacheurl"             => $row->cacheurl,
			}
		);
	}
	return $self->success( \@data );
}

sub get_summary {
	my $self = shift;

	my $metric_type  = $self->param("metric");
	my $start        = $self->param("start");
	my $end          = $self->param("end");
	my $interval     = $self->param("interval");
	my $window_start = $self->param("window_start");
	my $window_end   = $self->param("window_end");
	my $location     = "all";                          # NOTE: We can easily turn this into a param in the future if/when necessary

	my $id = $self->param('id');

	my $helper = new Utils::Helper( { mojo => $self } );

	if ( $helper->is_valid_delivery_service($id) ) {
		if ( $helper->is_delivery_service_assigned($id) ) {
			my $result = $self->db->resultset("Deliveryservice")->search( { id => $self->param('id') } )->single();
			my $param =
				$self->db->resultset('ProfileParameter')
				->search( { -and => [ 'parameter.name' => 'CDN_name', 'parameter.name' => 'CDN_name', 'me.profile' => $result->profile->id ] },
				{ prefetch => [ 'parameter', 'profile' ] } )->single();
			my $cdn_name = $param->parameter->value;
			my $match    = $cdn_name . ":" . $result->xml_id . ":all:all:" . $metric_type;
			my $data     = $self->get_stats( $match, $start, $end, $interval, $window_start, $window_end );

			if ( defined($data) && ref($data) eq "HASH" && exists( $data->{summary} ) ) {
				$self->success( { summary => $data->{summary} } );
			}
			else {
				$self->success( get_summary_zero_values() );
			}
		}
		else {
			$self->forbidden();
		}
	}
	else {
		$self->success( {} );
	}
}

sub get_summary_zero_values {
	my $response = ();
	$response->{"ninetyFifth"} = 0;
	$response->{"average"}     = 0;
	$response->{"min"}         = 0;
	$response->{"max"}         = 0;
	$response->{"total"}       = 0;
	return $response;
}

sub routing {
	my $self = shift;

	# get and pass { cdn_name => $foo } into get_routing_stats
	my $id = $self->param('id');

	my $helper = new Utils::Helper( { mojo => $self } );

	if ( $helper->is_valid_delivery_service($id) ) {
		if ( $helper->is_delivery_service_assigned($id) ) {
			my $result = $self->db->resultset("Deliveryservice")->search( { id => $self->param('id') } )->single();
			my $param =
				$self->db->resultset('ProfileParameter')
				->search( { -and => [ 'parameter.name' => 'CDN_name', 'parameter.name' => 'CDN_name', 'me.profile' => $result->profile->id ] },
				{ prefetch => [ 'parameter', 'profile' ] } )->single();
			my $cdn_name = $param->parameter->value;
			my $stat_key = lc( $result->type->name ) . "Map";    # dnsMap/httpMap in /crs/stats
			my $re_rs    = $result->deliveryservice_regexes;
			my @patterns;

			while ( my $re_row = $re_rs->next ) {
				push( @patterns, $re_row->regex->pattern );
			}

			$self->get_routing_stats( { stat_key => $stat_key, patterns => \@patterns, cdn_name => $cdn_name } );
		}
		else {
			$self->forbidden();
		}
	}
	else {
		$self->not_found();
	}
}

sub metrics {
	my $self       = shift;
	my $id         = $self->param("id");
	my $metric     = $self->param("metric");
	my $start      = $self->param("start");          # start time in secs since 1970
	my $end        = $self->param("end");            # end time in secs since 1970
	my $stats_only = $self->param("stats") || 0;     # stats only
	my $data_only  = $self->param("data") || 0;      # data only
	my $type       = $self->param("server_type");    # mid or edge

	my $config = $self->get_config($metric);
	my $helper = new Utils::Helper::Datasource( { mojo => $self } );

	if ( $valid_server_types->{$type} && defined($config) && $helper->is_valid_delivery_service($id) ) {
		if ( $helper->is_delivery_service_assigned($id) ) {
			$start =~ s/\.\d+$//g;
			$end =~ s/\.\d+$//g;

			for my $kvp ( @{ $config->{get_kvp}->( $helper->get_delivery_service_name($id), $valid_server_types->{$type}, $start, $end ) } ) {
				$helper->kv( $kvp->{key}, $kvp->{value} );
			}
			return $self->build_etl_metrics_response( $helper, $config, $start, $end, $stats_only, $data_only );
		}
		else {
			$self->forbidden();
		}
	}
	else {
		$self->success( get_zero_values( $stats_only, $data_only ) );
	}
}

sub get_zero_values {
	my $stats_only = shift;
	my $data_only  = shift;
	my $response   = ();
	$response->{"stats"}{"95thPercentile"} = 0;
	$response->{"stats"}{"98thPercentile"} = 0;
	$response->{"stats"}{"5thPercentile"}  = 0;
	$response->{"stats"}{"mean"}           = 0;
	$response->{"stats"}{"count"}          = 0;
	$response->{"stats"}{"min"}            = 0;
	$response->{"stats"}{"max"}            = 0;
	$response->{"stats"}{"sum"}            = 0;
	$response->{"data"}                    = [];
	if ($stats_only) {
		delete( $response->{"data"} );
	}
	elsif ($data_only) {
		delete( $response->{"stats"} );
	}
	return [$response];
}

sub capacity {
	my $self = shift;

	# get and pass { cdn_name => $foo } into get_cache_capacity
	my $id = $self->param('id');

	my $helper = new Utils::Helper( { mojo => $self } );

	if ( $helper->is_valid_delivery_service($id) ) {
		if ( $helper->is_delivery_service_assigned($id) ) {
			my $result = $self->db->resultset("Deliveryservice")->search( { id => $self->param('id') } )->single();
			my $param =
				$self->db->resultset('ProfileParameter')
				->search( { -and => [ 'parameter.name' => 'CDN_name', 'parameter.name' => 'CDN_name', 'me.profile' => $result->profile->id ] },
				{ prefetch => [ 'parameter', 'profile' ] } )->single();
			my $cdn_name = $param->parameter->value;

			$self->get_cache_capacity( { delivery_service => $result->xml_id, cdn_name => $cdn_name } );
		}
		else {
			$self->forbidden();
		}
	}
	else {
		$self->not_found();
	}
}

sub health {
	my $self = shift;
	my $id   = $self->param('id');

	my $helper = new Utils::Helper( { mojo => $self } );

	if ( $helper->is_valid_delivery_service($id) ) {
		if ( $helper->is_delivery_service_assigned($id) ) {
			my $result = $self->db->resultset("Deliveryservice")->search( { id => $self->param('id') } )->single();
			my $param =
				$self->db->resultset('ProfileParameter')
				->search( { -and => [ 'parameter.name' => 'CDN_name', 'parameter.name' => 'CDN_name', 'me.profile' => $result->profile->id ] },
				{ prefetch => [ 'parameter', 'profile' ] } )->single();
			my $cdn_name = $param->parameter->value;

			return ( $self->get_cache_health( { server_type => "caches", delivery_service => $result->xml_id, cdn_name => $cdn_name } ) );
		}
		else {
			$self->forbidden();
		}
	}
	else {
		$self->not_found();
	}
}

sub state {

	my $self = shift;
	my $id   = $self->param('id');

	my $helper = new Utils::Helper( { mojo => $self } );

	if ( $helper->is_valid_delivery_service($id) ) {
		if ( $helper->is_delivery_service_assigned($id) || &is_oper($self) ) {
			my $result = $self->db->resultset("Deliveryservice")->search( { id => $self->param('id') } )->single();
			my $param =
				$self->db->resultset('ProfileParameter')
				->search( { -and => [ 'parameter.name' => 'CDN_name', 'parameter.name' => 'CDN_name', 'me.profile' => $result->profile->id ] },
				{ prefetch => [ 'parameter', 'profile' ] } )->single();
			my $cdn_name = $param->parameter->value;
			my $ds_name  = $result->xml_id;

			my $rascal_data = $self->get_rascal_state_data( { type => "RASCAL", state_type => "deliveryServices", cdn_name => $cdn_name } );

			# scalar refs get converted into json booleans
			my $data = {
				enabled  => \0,
				failover => {
					enabled     => \0,
					configured  => \0,
					destination => undef,
					locations   => []
				}
			};

			if ( exists( $rascal_data->{$cdn_name} ) && exists( $rascal_data->{$cdn_name}->{state}->{$ds_name} ) ) {
				my $health_config = $self->get_health_config($cdn_name);
				my $c             = $rascal_data->{$cdn_name}->{config}->{deliveryServices}->{$ds_name};
				my $r             = $rascal_data->{$cdn_name}->{state}->{$ds_name};

				if ( exists( $health_config->{deliveryServices}->{$ds_name} ) ) {
					my $h = $health_config->{deliveryServices}->{$ds_name};

					if ( $h->{status} eq "REPORTED" ) {
						$data->{enabled} = \1;
					}

					if ( !$r->{isAvailable} ) {
						$data->{failover}->{enabled}   = \1;
						$data->{failover}->{locations} = $r->{disabledLocations};
					}

					if ( exists( $h->{"health.threshold.total.kbps"} ) ) {

						# get current kbps, calculate percent used
						$data->{failover}->{configured} = \1;
						push( @{ $data->{failover}->{limits} }, { metric => "total_kbps", limit => $h->{"health.threshold.total.kbps"} } );
					}

					if ( exists( $h->{"health.threshold.total.tps_total"} ) ) {

						# get current tps, calculate percent used
						$data->{failover}->{configured} = \1;
						push( @{ $data->{failover}->{limits} }, { metric => "total_tps", limit => $h->{"health.threshold.total.tps_total"} } );
					}

					if ( exists( $c->{bypassDestination} ) ) {
						my @k        = keys( %{ $c->{bypassDestination} } );
						my $type     = shift(@k);
						my $location = undef;

						if ( $type eq "DNS" ) {
							$location = $c->{bypassDestination}->{$type}->{ip};
						}
						elsif ( $type eq "HTTP" ) {
							my $port = ( exists( $c->{bypassDestination}->{$type}->{port} ) ) ? ":" . $c->{bypassDestination}->{$type}->{port} : "";
							$location = sprintf( "http://%s%s", $c->{bypassDestination}->{$type}->{fqdn}, $port );
						}

						$data->{failover}->{destination} = {
							type     => $type,
							location => $location
						};
					}
				}
			}

			$self->success($data);
		}
		else {
			$self->forbidden();
		}
	}
	else {
		$self->not_found();
	}
}

sub peakusage {
	my $self            = shift;
	my $dsid            = $self->param('ds');
	my $cachegroup_name = $self->param('name');
	my $peak_usage_type = $self->param('peak_usage_type');
	my $start           = $self->param('start');
	my $end             = $self->param('end');
	my $interval        = $self->param('interval');
	my $helper          = new Utils::Helper( { mojo => $self } );
	if ( $helper->is_valid_delivery_service($dsid) ) {

		if ( $helper->is_delivery_service_assigned($dsid) ) {
			return $self->get_ds_usage( $dsid, $cachegroup_name, $peak_usage_type, $start, $end, $interval );
		}
		else {
			return $self->forbidden();
		}
	}
	else {
		$self->success( {} );
	}

}

1;
