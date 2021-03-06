%%%-------------------------------------------------------------------
%%% @copyright (C) 2012-2014, 2600Hz INC
%%% @doc
%%% Renders a custom account email template, or the system default,
%%% and sends the email with voicemail attachment to the user.
%%% @end
%%%
%%% @contributors
%%%   Karl Anderson <karl@2600hz.org>
%%%-------------------------------------------------------------------
-module(notify_ported).

-export([init/0, handle_req/2]).

-include("notify.hrl").

-define(DEFAULT_TEXT_TMPL, 'notify_ported_text_tmpl').
-define(DEFAULT_HTML_TMPL, 'notify_ported_html_tmpl').
-define(DEFAULT_SUBJ_TMPL, 'notify_ported_subj_tmpl').

-define(MOD_CONFIG_CAT, <<(?NOTIFY_CONFIG_CAT)/binary, ".ported">>).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% initialize the module
%% @end
%%--------------------------------------------------------------------
-spec init() -> 'ok'.
init() ->
    %% ensure the vm template can compile, otherwise crash the processes
    {'ok', _} = notify_util:compile_default_text_template(?DEFAULT_TEXT_TMPL, ?MOD_CONFIG_CAT),
    {'ok', _} = notify_util:compile_default_html_template(?DEFAULT_HTML_TMPL, ?MOD_CONFIG_CAT),
    {'ok', _} = notify_util:compile_default_subject_template(?DEFAULT_SUBJ_TMPL, ?MOD_CONFIG_CAT),
    lager:debug("init done for ~s", [?MODULE]).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% process the AMQP requests
%% @end
%%--------------------------------------------------------------------
-spec handle_req(wh_json:object(), proplist()) -> 'ok'.
handle_req(JObj, _Props) ->
    'true' = wapi_notifications:ported_v(JObj),
    wh_util:put_callid(JObj),

    lager:debug("a ported notice has been received, sending email notification"),

    {'ok', Account} = notify_util:get_account_doc(JObj),

    Props = create_template_props(JObj, Account),

    CustomTxtTemplate = wh_json:get_value([<<"notifications">>, <<"ported">>, <<"email_text_template">>], Account),
    {'ok', TxtBody} = notify_util:render_template(CustomTxtTemplate, ?DEFAULT_TEXT_TMPL, Props),

    CustomHtmlTemplate = wh_json:get_value([<<"notifications">>, <<"ported">>, <<"email_html_template">>], Account),
    {'ok', HTMLBody} = notify_util:render_template(CustomHtmlTemplate, ?DEFAULT_HTML_TMPL, Props),

    CustomSubjectTemplate = wh_json:get_value([<<"notifications">>, <<"ported">>, <<"email_subject_template">>], Account),
    {'ok', Subject} = notify_util:render_template(CustomSubjectTemplate, ?DEFAULT_SUBJ_TMPL, Props),

    case notify_util:get_rep_email(Account) of
        'undefined' ->
            SysAdminEmail = whapps_config:get(?MOD_CONFIG_CAT, <<"default_to">>, <<"">>),
            build_and_send_email(TxtBody, HTMLBody, Subject, SysAdminEmail, Props);
        RepEmail ->
            build_and_send_email(TxtBody, HTMLBody, Subject, RepEmail, Props)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% create the props used by the template render function
%% @end
%%--------------------------------------------------------------------
-spec create_template_props(wh_json:object(), wh_json:object()) -> wh_proplist().
create_template_props(Event, Account) ->
    Admin = notify_util:find_admin(wh_json:get_value(<<"Authorized-By">>, Event)),
    [{<<"request">>, notify_util:json_to_template_props(Event)}
     ,{<<"account">>, notify_util:json_to_template_props(Account)}
     ,{<<"admin">>, notify_util:json_to_template_props(Admin)}
     ,{<<"service">>, notify_util:get_service_props(Account, ?MOD_CONFIG_CAT)}
     ,{<<"send_from">>, get_send_from(Admin)}
    ].

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec get_send_from(wh_json:object()) -> ne_binary().
get_send_from(Admin) ->
    DefaultFrom = wh_util:to_binary(node()),
    case whapps_config:get_is_true(?MOD_CONFIG_CAT, <<"send_from_admin_email">>, 'true') of
        'false' -> DefaultFrom;
        'true' -> wh_json:get_ne_value(<<"email">>, Admin, DefaultFrom)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% process the AMQP requests
%% @end
%%--------------------------------------------------------------------
-spec build_and_send_email(iolist(), iolist(), iolist(), ne_binary() | ne_binaries(), wh_proplist()) -> 'ok'.
build_and_send_email(TxtBody, HTMLBody, Subject, To, Props) when is_list(To)->
    _ = [build_and_send_email(TxtBody, HTMLBody, Subject, T, Props) || T <- To];
build_and_send_email(TxtBody, HTMLBody, Subject, To, Props) ->
    From = props:get_value(<<"send_from">>, Props),
    %% Content Type, Subtype, Headers, Parameters, Body
    Email = {<<"multipart">>, <<"mixed">>
                 ,[{<<"From">>, From}
                   ,{<<"To">>, To}
                   ,{<<"Subject">>, Subject}
                  ]
             ,[]
             ,[{<<"multipart">>, <<"alternative">>, [], []
                ,[{<<"text">>, <<"plain">>, [{<<"Content-Type">>, <<"text/plain">>}], [], iolist_to_binary(TxtBody)}
                  ,{<<"text">>, <<"html">>, [{<<"Content-Type">>, <<"text/html">>}], [], iolist_to_binary(HTMLBody)}
                 ]
               }
              ]
            },
    notify_util:send_email(From, To, Email).
