module Update exposing (Msg(..), ServerMsg(..), update, commandDescriptions)

import Debug
import Dict
import Form exposing (Form)
import Irc
import Model exposing (..)
import Ports
import Regex
import Time exposing (Time)
import WebSocket


{-| Messages that require there to be a valid server specified.
-}
type ServerMsg
    = AddLine BufferName Line
    | AddScrollback BufferName Line
    | ClearBuffer BufferName
    | CloseBuffer BufferName
    | ConnectIrc
    | CreateBuffer BufferName
    | DisconnectServer
    | RemoveServer
    | ReceiveRawLine String
    | SelectBuffer BufferName
    | SendLine Buffer String
    | SendRawLine String
    | StoreServer
    | TabCompleteLine Buffer


type Msg
    = ModifyServer ServerName ServerMsg
    | AddServer ServerMetadata
    | FormMsg Form.Msg
    | MultiMsg (List Msg)
    | RefreshScroll Bool
    | SendNotification String String
    | ShowAddServerForm
    | Tick Time
    | TypeLine String
    | Noop


commandDescriptions : List ( String, String )
commandDescriptions =
    [ ( "/server save", "save the configuration for the current server to localstorage" )
    , ( "/server delete", "remove the current configuration from localstorage" )
    , ( "/server disconnect", "close the IRC connection to the current server" )
    , ( "/join #channel", "join and switch to #channel" )
    , ( "/part", "leave the current channel" )
    , ( "/part #channel", "leave #channel" )
    , ( "/close", "close the current buffer window" )
    , ( "/clear", "clear out the contents of the current buffer window" )
    , ( "/ping nick", "send CTCP PING to nick" )
    , ( "/names", "list the (first 100) users in the current channel" )
    , ( "/nick newNick", "changes current nick to newNick" )
    , ( "/ns", "shorthand to message NickServ" )
    , ( "/cs", "shorthand to message ChanServ" )
    , ( "/query nick", "open a direct message buffer window with nick" )
    , ( "/quote something", "send \"something\" to the server directly" )
    , ( "/help", "list available slash commands." )
    ]


modifyServer : Server -> ServerMsg -> Msg
modifyServer server msg =
    ModifyServer server.meta.name msg


updateServer : Server -> ServerMsg -> Model -> ( Model, Cmd Msg )
updateServer server msg model =
    case msg of
        AddLine bufferName line ->
            let
                buf =
                    getOrCreateBuffer server bufferName
                        |> (\b -> { b | buffer = appendLine b.buffer line })

                model_ =
                    setBuffer server buf model

                nickRegexp =
                    Regex.regex ("\\b" ++ server.meta.nick ++ "\\b")

                matchesNick =
                    Regex.contains nickRegexp line.message

                isDirectMessage =
                    (server.meta.nick /= line.nick)
                        && not (targetIsChannel bufferName)

                body =
                    String.concat [ "<", line.nick, ">: ", line.message ]

                cmd =
                    if not buf.isServer && (matchesNick || isDirectMessage) then
                        SendNotification buf.name body
                    else
                        Noop
            in
                update cmd model_

        AddScrollback bufferName line ->
            model ! [ Ports.saveScrollback ( server.meta.name, bufferName, line ) ]

        ClearBuffer bufferName ->
            case getBuffer server bufferName of
                Just buffer ->
                    let
                        buffer_ =
                            { buffer | buffer = [] }
                    in
                        setBuffer server buffer_ model
                            ! [ Ports.clearScrollback ( server.meta.name, bufferName ) ]

                Nothing ->
                    Debug.crash "bad buffer name given?" bufferName

        CloseBuffer bufferName ->
            let
                current =
                    if model.current == Just ( server.meta.name, bufferName ) then
                        Nothing
                    else
                        model.current

                server_ =
                    { server | buffers = Dict.remove (String.toLower bufferName) server.buffers }

                model_ =
                    { model
                        | current = current
                        , servers = Dict.insert server.meta.name server_ model.servers
                    }
            in
                model_ ! []

        ConnectIrc ->
            let
                passMsg =
                    server.pass
                        |> Maybe.map (\pass -> "PASS " ++ pass)
                        |> Maybe.withDefault ""

                lines =
                    [ passMsg
                    , "CAP REQ znc.in/server-time-iso"
                    , "CAP REQ server-time"
                    , "CAP END"
                    , "NICK " ++ server.meta.nick
                    , "USER " ++ server.meta.nick ++ " * * :" ++ server.meta.nick
                    ]
            in
                lines
                    |> List.map (\line -> modifyServer server (SendRawLine line))
                    |> flip batchMessage model

        CreateBuffer bufferName ->
            let
                buffer =
                    Model.newBuffer bufferName

                model_ =
                    setBuffer server buffer model
            in
                model_ ! []

        DisconnectServer ->
            { model | servers = Dict.remove server.meta.name model.servers } ! []

        RemoveServer ->
            ( model, Ports.modifyServerStore ( server.meta, "REMOVE" ) )

        ReceiveRawLine line ->
            let
                -- Grab the time out of the message or default to current time.
                getTs msg =
                    msg.time |> Maybe.withDefault model.currentTime
            in
                -- There are a couple non standard commands the proxy
                -- server can send.
                case line of
                    "*CONNECTED" ->
                        update (modifyServer server ConnectIrc) model

                    _ ->
                        Irc.splitMessage line
                            |> Maybe.map (\msg -> handleCommand server (getTs msg) msg model)
                            |> Maybe.withDefault ( model, Cmd.none )

        SelectBuffer bufferName ->
            let
                buffer =
                    getOrCreateBuffer server bufferName
                        |> (\chan -> { chan | lastChecked = model.currentTime })

                model_ =
                    setBuffer server buffer model
                        |> (\model ->
                                { model
                                    | current = Just ( server.meta.name, bufferName )
                                    , newServerForm = Nothing
                                }
                           )
            in
                update (RefreshScroll True) model_

        StoreServer ->
            ( model, Ports.modifyServerStore ( server.meta, "STORE" ) )

        SendLine buf line ->
            if model.inputLine == "" then
                model ! []
            else
                { model | inputLine = "" }
                    |> batchMessage (sendLine server buf line model)
                    |> andThen (RefreshScroll True)

        SendRawLine line ->
            ( model, WebSocket.send server.socket line )

        TabCompleteLine buffer ->
            let
                words =
                    String.split " " model.inputLine

                lastWord =
                    -- We want to tab complete "something|", not "something |".
                    case List.reverse words |> List.head of
                        Just "" ->
                            Nothing

                        word ->
                            word

                -- If this gets called while nicks are still
                -- loading, just sort alphabetically,
                -- otherwise choose the most recent user.
                completion =
                    lastWord
                        |> Maybe.map
                            (\word ->
                                case buffer.users of
                                    UsersLoading list ->
                                        List.filter (String.startsWith word) list
                                            |> List.sort

                                    UsersLoaded set ->
                                        set
                                            |> Dict.filter (\nick _ -> String.startsWith word nick)
                                            |> Dict.toList
                                            |> List.sortBy (\( nick, lastMessage ) -> -lastMessage)
                                            |> List.map Tuple.first
                            )
                        -- Don't complete our own nick
                        |> Maybe.map (List.filter (\nick -> not (nick == server.meta.nick)))
                        -- And just take the first.
                        |> Maybe.andThen List.head

                inputLine =
                    case completion of
                        Just completion ->
                            case words of
                                -- if we're tab completing the first word,
                                -- assume this is a nick highlight.
                                [ nick ] ->
                                    completion ++ ": "

                                words ->
                                    [ completion ]
                                        |> List.append (List.take (List.length words - 1) words)
                                        |> String.join " "

                        Nothing ->
                            model.inputLine
            in
                { model | inputLine = inputLine } ! []


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        ModifyServer serverName msg ->
            case getServer model serverName of
                Just server ->
                    updateServer server msg model

                Nothing ->
                    Debug.crash "unknown server given" ( serverName, msg )

        AddServer meta ->
            let
                -- TODO: We no longer send meta.name to differentiate the query
                -- strings so elm opens up multiple websockets
                -- So you can only have one socket per URL

                server =
                    { socket = meta.wsUrl
                    , pass = meta.pass
                    , meta = meta
                    , buffers = Dict.empty
                    }

                servers_ =
                    model.servers
                        |> Dict.insert meta.name server
            in
                { model | servers = servers_ } ! []

        TypeLine str ->
            { model | inputLine = str } ! []

        RefreshScroll force ->
            ( model, Ports.refreshScrollPosition force )

        SendNotification title message ->
            ( model, Ports.sendNotification ( title, message ) )

        Tick time ->
            let
                model_ =
                    case getActive model of
                        Just ( server, buf ) ->
                            setBuffer server
                                { buf | lastChecked = time }
                                model

                        Nothing ->
                            model
            in
                ( { model_ | currentTime = time }, Cmd.none )

        FormMsg formMsg ->
            let
                form_ =
                    model.newServerForm

                serverMeta =
                    form_
                        |> Maybe.andThen Form.getOutput
            in
                case ( formMsg, serverMeta ) of
                    ( Form.Submit, Just serverMeta ) ->
                        update (AddServer serverMeta) { model | newServerForm = Nothing }

                    _ ->
                        -- FIXME: gnarly.
                        { model
                            | newServerForm =
                                form_
                                    |> Maybe.map (Form.update newServerValidation formMsg)
                        }
                            ! []

        ShowAddServerForm ->
            let
                form =
                    Form.initial [] newServerValidation
            in
                { model | newServerForm = Just form } ! []

        MultiMsg msgs ->
            batchMessage msgs model

        Noop ->
            ( model, Cmd.none )


{-| Nabbed from <http://stackoverflow.com/a/42050830>
-}
andThen : Msg -> ( Model, Cmd Msg ) -> ( Model, Cmd Msg )
andThen msg ( model, cmd ) =
    let
        ( newModel, newCmd ) =
            update msg model
    in
        newModel ! [ cmd, newCmd ]


batchMessage : List Msg -> Model -> ( Model, Cmd Msg )
batchMessage msgs model =
    List.foldr andThen ( model, Cmd.none ) msgs


targetIsChannel : String -> Bool
targetIsChannel target =
    (String.startsWith "#" target)
        || (String.startsWith "&" target)


handleMessage : Server -> UserInfo -> String -> String -> Time.Time -> Model -> ( Model, Cmd Msg )
handleMessage server user target message ts model =
    let
        target_ =
            if targetIsChannel target then
                target
            else
                user.nick

        nick =
            if user.isServer then
                server.meta.name
            else
                user.nick

        colorCodeRegex =
            Regex.regex "\x03\\d{2}(?:,\\d{2})?"

        -- FIXME: for now we just strip out color codes, but this
        -- FIXME: should probably be supported.
        stripped =
            message
                |> Regex.replace Regex.All colorCodeRegex (\_ -> "")

        newLine =
            { ts = ts, nick = nick, message = stripped }

        newMsg =
            AddLine target_ newLine |> modifyServer server

        refreshMsg =
            if Just ( server.meta.name, target_ ) == model.current then
                RefreshScroll False
            else
                Noop

        scrollbackMsg =
            if not user.isServer && server.meta.saveScrollback then
                AddScrollback target_ newLine |> modifyServer server
            else
                Noop

        model_ =
            if not user.isServer then
                getBuffer server target
                    |> Maybe.map (setNickTimestamp nick ts)
                    |> Maybe.map (\buf -> setBuffer server buf model)
                    |> Maybe.withDefault model
            else
                model
    in
        update (MultiMsg [ newMsg, refreshMsg, scrollbackMsg ]) model_


handleCommand : Server -> Time.Time -> Irc.ParsedMessage -> Model -> ( Model, Cmd Msg )
handleCommand server ts msg model =
    case ( msg.command, msg.params ) of
        -- Clean out the buffers when we rejoin.
        ( "001", _ ) ->
            let
                buffers_ =
                    server.buffers
                        |> Dict.map (\_ v -> { v | buffer = [] })

                server_ =
                    { server | buffers = buffers_ }

                model_ =
                    model.servers
                        |> Dict.insert server.meta.name server_
                        |> (\servers -> { model | servers = servers })
            in
                model_ ! [ Ports.requestScrollback server.meta.name ]

        ( "PING", params ) ->
            let
                pong =
                    "PONG " ++ String.concat params
            in
                updateServer server (SendRawLine pong) model

        ( "JOIN", [ channel ] ) ->
            let
                weJoined =
                    server.meta.nick == msg.user.nick

                buffer =
                    getBuffer server channel
                        |> Maybe.withDefault (newBuffer channel)
                        |> addNicks [ msg.user.nick ]

                -- don't report unread messages in the past.
                lastChecked =
                    if weJoined then
                        model.currentTime
                    else
                        buffer.lastChecked

                model_ =
                    setBuffer server { buffer | lastChecked = lastChecked } model

                current_ =
                    -- We want to switch to the channel if we haven't
                    -- joined anything else yet.
                    if weJoined && model.current == Nothing then
                        Just ( server.meta.name, buffer.name )
                    else
                        model.current
            in
                { model_ | current = current_ } ! []

        ( "PART", channel :: reason ) ->
            case getBuffer server channel of
                Just buf ->
                    let
                        buf_ =
                            removeNick msg.user.nick buf

                        model_ =
                            setBuffer server buf_ model

                        ( current, cmd ) =
                            if server.meta.nick == msg.user.nick then
                                ( Nothing, CloseBuffer channel |> modifyServer server )
                            else
                                ( model.current, Noop )
                    in
                        update cmd { model_ | current = current }

                Nothing ->
                    let
                        _ =
                            Debug.log "odd: PART for channel we aren't in." channel
                    in
                        ( model, Cmd.none )

        ( "QUIT", _ ) ->
            let
                server_ =
                    server.buffers
                        |> Dict.map (\_ buf -> removeNick msg.user.nick buf)
                        |> (\buffers -> { server | buffers = buffers })

                model_ =
                    { model | servers = Dict.insert server.meta.name server model.servers }
            in
                ( model_, Cmd.none )

        ( "PRIVMSG", [ target, message ] ) ->
            handleMessage server msg.user target message ts model

        ( "NOTICE", [ target, message ] ) ->
            let
                formatCtcp msg =
                    case String.words msg of
                        [ "PING", timeString ] ->
                            let
                                time =
                                    timeString
                                        |> String.toFloat
                                        |> Result.withDefault 0

                                pingTime =
                                    (model.currentTime - time)
                                        |> Time.inSeconds
                                        |> toString
                            in
                                "PONG: " ++ pingTime ++ " secs"

                        _ ->
                            "CTCP:" ++ msg

                notice =
                    if String.startsWith "\x01" message then
                        formatCtcp (String.split "\x01" message |> String.concat)
                    else
                        "NOTICE: " ++ message
            in
                handleMessage server msg.user target notice ts model

        -- You have been marked as being away
        ( "306", _ ) ->
            model ! []

        -- Channel topic
        ( "332", [ _, target, topic ] ) ->
            let
                buf =
                    getOrCreateBuffer server target

                buf_ =
                    { buf | topic = Just topic }
            in
                ( setBuffer server buf_ model, Cmd.none )

        ( "333", _ ) ->
            model ! []

        -- NAMES list
        ( "353", [ _, _, channel, usersString ] ) ->
            let
                specialChars =
                    Regex.regex "[%@~\\+]"

                stripSpecial =
                    Regex.replace Regex.All specialChars (\_ -> "")

                userList =
                    stripSpecial usersString
                        |> String.words

                buf =
                    getOrCreateBuffer server channel
                        |> addNicks userList

                model_ =
                    setBuffer server buf model
            in
                model_ ! []

        -- END of /NAMES
        ( "366", [ _, channel, _ ] ) ->
            case getBuffer server channel of
                Just buf ->
                    let
                        users =
                            case buf.users of
                                UsersLoading list ->
                                    list
                                        |> List.map (\nick -> ( nick, 0 ))
                                        |> Dict.fromList
                                        |> UsersLoaded

                                set ->
                                    set

                        model_ =
                            setBuffer server { buf | users = users } model
                    in
                        model_ ! []

                _ ->
                    let
                        _ =
                            Debug.log "weird: 366 for unknown channel" channel
                    in
                        model ! []

        ( "NICK", [ nick ] ) ->
            let
                myNick =
                    if msg.user.nick == server.meta.nick then
                        nick
                    else
                        server.meta.nick

                serverMeta_ =
                    server.meta |> (\meta -> { meta | nick = myNick })

                server_ =
                    server.buffers
                        |> Dict.map
                            (\_ buf ->
                                removeNick msg.user.nick buf
                                    |> addNicks [ nick ]
                            )
                        |> (\buffers ->
                                { server
                                    | buffers = buffers
                                    , meta = serverMeta_
                                }
                           )

                model_ =
                    { model | servers = Dict.insert server.meta.name server_ model.servers }
            in
                model_ ! []

        _ ->
            let
                msgText =
                    String.join " " msg.params

                newLine =
                    { ts = ts
                    , nick = msg.user.nick
                    , message = String.join ": " [ msg.command, msgText ]
                    }

                _ =
                    Debug.log "unknown msg" msg
            in
                update
                    (MultiMsg
                        [ AddLine serverBufferName newLine |> modifyServer server
                        , RefreshScroll False
                        ]
                    )
                    model


{-| Handle sending messages to the server (and all the slash commands
and such that could be used)
-}
sendLine : Server -> Buffer -> String -> Model -> List Msg
sendLine server buf line model =
    let
        privmsg target msg =
            let
                line =
                    { ts = model.currentTime
                    , nick = server.meta.nick
                    , message = msg
                    }

                rawLine =
                    String.join " " [ "PRIVMSG", target, ":" ++ msg ]
            in
                if buf.isServer then
                    addErrorMessage "use /quote to send messages directly to the server"
                else
                    [ SendRawLine rawLine |> modifyServer server
                    , AddLine target line |> modifyServer server
                    , if server.meta.saveScrollback then
                        AddScrollback target line |> modifyServer server
                      else
                        Noop
                    ]

        ctcp target command msg =
            let
                msg_ =
                    String.concat [ "\x01", command, " ", msg, "\x01" ]
            in
                privmsg target msg_

        -- shortened versions of common commands
        commandAliases cmd =
            Dict.fromList
                [ ( "/j", "/join" )
                , ( "/msg", "/privmsg" )
                , ( "/pm", "/privmsg" )
                , ( "/q", "/query" )
                ]
                |> Dict.get cmd
                |> Maybe.withDefault cmd

        addErrorMessage msg =
            let
                line =
                    { ts = model.currentTime
                    , nick = "*error"
                    , message = msg
                    }
            in
                [ AddLine buf.name line |> modifyServer server ]

        slashCommand cmd params =
            case ( String.toLower cmd, params ) of
                ( "/join", [ channel ] ) ->
                    if targetIsChannel channel then
                        [ SendRawLine ("JOIN " ++ channel)
                        , SelectBuffer channel
                        ]
                            |> List.map (modifyServer server)
                    else
                        addErrorMessage "channel names must begin with #"

                ( "/query", [ nick ] ) ->
                    if targetIsChannel nick then
                        addErrorMessage "can only initiate queries with users"
                    else
                        [ modifyServer server (SelectBuffer nick) ]

                ( "/part", [] ) ->
                    slashCommand "/part" [ buf.name ]

                ( "/part", [ channel ] ) ->
                    [ SendRawLine ("PART " ++ channel) |> modifyServer server
                    , CloseBuffer channel |> modifyServer server
                    ]

                ( "/close", [] ) ->
                    if buf.isServer then
                        addErrorMessage "use `/server disconnect` instead"
                    else
                        [ CloseBuffer buf.name |> modifyServer server
                        , ClearBuffer buf.name |> modifyServer server
                        ]

                ( "/clear", [] ) ->
                    [ ClearBuffer buf.name |> modifyServer server ]

                ( "/me", rest ) ->
                    let
                        msg =
                            String.join " " rest
                    in
                        ctcp buf.name "ACTION" msg

                ( "/privmsg", target :: rest ) ->
                    privmsg target (String.join " " rest)

                ( "/ping", [ target ] ) ->
                    ctcp target "PING" (toString model.currentTime)

                ( "/ns", rest ) ->
                    privmsg "NickServ" (String.join " " rest)

                ( "/cs", rest ) ->
                    privmsg "ChanServ" (String.join " " rest)

                ( "/names", [] ) ->
                    let
                        nickList =
                            case buf.users of
                                UsersLoading list ->
                                    list

                                UsersLoaded set ->
                                    Dict.toList set
                                        |> List.map Tuple.first

                        nicks =
                            List.take 100 nickList

                        message =
                            [ List.length nickList |> toString, "users:" ]
                                ++ nicks

                        line =
                            { ts = model.currentTime
                            , message = String.join " " message
                            , nick = buf.name
                            }
                    in
                        [ AddLine buf.name line |> modifyServer server ]

                ( "/server", [ "save" ] ) ->
                    [ modifyServer server StoreServer ]

                ( "/server", [ "delete" ] ) ->
                    [ modifyServer server DisconnectServer
                    , modifyServer server RemoveServer
                    ]

                ( "/server", [ "disconnect" ] ) ->
                    [ modifyServer server DisconnectServer ]

                ( "/help", _ ) ->
                    let
                        lines =
                            commandDescriptions
                                |> List.map (\( cmd, desc ) -> cmd ++ "\t--\t" ++ desc)
                                |> List.map
                                    (\line ->
                                        { ts = model.currentTime
                                        , message = line
                                        , nick = buf.name
                                        }
                                    )

                        cmds =
                            List.map (AddLine buf.name) lines
                                |> List.map (modifyServer server)
                    in
                        cmds

                ( "/nick", [ nick ] ) ->
                    [ SendRawLine ("NICK " ++ nick) |> modifyServer server ]

                ( "/quote", rest ) ->
                    [ SendRawLine (String.join " " rest) |> modifyServer server ]

                _ ->
                    addErrorMessage "unknown command, did you forget to /quote?"
    in
        case ( String.left 1 line, String.words line ) of
            ( "/", cmd :: params ) ->
                slashCommand (commandAliases cmd) params

            _ ->
                privmsg buf.name line
