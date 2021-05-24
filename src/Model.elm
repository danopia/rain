module Model exposing (..)

import Date exposing (Date)
import Dict exposing (Dict)
import Form exposing (Form)
import Form.Validate as Validate exposing (..)
import Time exposing (Time)


type alias ServerName =
    String


type alias BufferName =
    String


type alias ServerBuffer =
    ( ServerName, BufferName )


serverBufferName : BufferName
serverBufferName =
    ":server"


type alias ServerMetadata =
    { wsUrl : String
    , nick : String
    , pass : Maybe String
    , name : String
    , saveScrollback : Bool
    }


type alias Server =
    { socket : String
    , meta : ServerMetadata
    , pass : Maybe String
    , buffers : Dict BufferName Buffer
    }


type alias Line =
    { ts : Time.Time
    , nick : String
    , message : String
    }


type alias DayGroup =
    { date : Date.Date
    , lineGroups : List LineGroup
    }


type alias LineGroup =
    { ts : Time.Time
    , nick : String
    , messages : List Line
    }


type alias LineBuffer =
    List DayGroup


type alias UserInfo =
    { nick : String
    , host : String
    , real : String
    , isServer : Bool
    }


{-| to avoid choking on large channels, we wait to uniquify the user names
until we receive the "end of names list" message from the server.

UsersLoaded is nick => last message

-}
type UserList
    = UsersLoading (List String)
    | UsersLoaded (Dict String Time.Time)


type alias Buffer =
    { name : String
    , users : UserList
    , topic : Maybe String
    , buffer : LineBuffer
    , lastChecked : Time.Time
    , isServer : Bool
    }


type alias Model =
    { servers : Dict ServerName Server
    , current : Maybe ServerBuffer
    , inputLine : String
    , currentTime : Time
    , newServerForm : Maybe (Form () ServerMetadata)
    }


newServerValidation : Validation () ServerMetadata
newServerValidation =
    map5 ServerMetadata
        (field "wsUrl" string)
        (field "nick" string)
        (field "pass" <| maybe string)
        (field "name" string)
        (field "saveScrollback" bool)


initialModel : Model
initialModel =
    { servers = Dict.empty
    , current = Nothing
    , inputLine = ""
    , currentTime = 0
    , newServerForm = Nothing
    }


newBuffer : String -> Buffer
newBuffer name =
    { name = name
    , users = UsersLoading []
    , topic = Nothing
    , buffer = []
    , lastChecked = 0
    , isServer = name == serverBufferName
    }


setNickTimestamp : String -> Time.Time -> Buffer -> Buffer
setNickTimestamp nick ts buf =
    case buf.users of
        UsersLoading list ->
            buf

        UsersLoaded set ->
            { buf | users = UsersLoaded (Dict.insert nick ts set) }


addNicks : List String -> Buffer -> Buffer
addNicks nicks buf =
    case buf.users of
        UsersLoading list ->
            { buf | users = UsersLoading (list ++ nicks) }

        UsersLoaded set ->
            let
                users =
                    nicks
                        |> List.map (\nick -> ( nick, 0 ))
                        |> Dict.fromList
                        |> Dict.union set
            in
                { buf | users = UsersLoaded users }


removeNick : String -> Buffer -> Buffer
removeNick nick buf =
    case buf.users of
        UsersLoading list ->
            { buf | users = UsersLoading (List.filter (\x -> not (x == nick)) list) }

        UsersLoaded set ->
            { buf | users = UsersLoaded (Dict.remove nick set) }


getServer : Model -> ServerName -> Maybe Server
getServer model serverName =
    Dict.get serverName model.servers


setBuffer : Server -> Buffer -> Model -> Model
setBuffer server buf model =
    let
        name_ =
            String.toLower buf.name

        server_ =
            let
                buffers =
                    Dict.insert name_ buf server.buffers
            in
                { server | buffers = buffers }
    in
        { model | servers = Dict.insert server.meta.name server_ model.servers }


getBuffer : Server -> BufferName -> Maybe Buffer
getBuffer server bufferName =
    Dict.get (String.toLower bufferName) server.buffers


getServerBuffer : Model -> ServerBuffer -> Maybe ( Server, Buffer )
getServerBuffer model ( sn, bn ) =
    let
        server =
            getServer model sn

        buffer =
            server
                |> Maybe.andThen (\server -> getBuffer server bn)
    in
        Maybe.map2 (,) server buffer


getOrCreateBuffer : Server -> BufferName -> Buffer
getOrCreateBuffer server bufferName =
    getBuffer server bufferName
        |> Maybe.withDefault (newBuffer bufferName)


getActive : Model -> Maybe ( Server, Buffer )
getActive model =
    model.current |> Maybe.andThen (getServerBuffer model)


getActiveBuffer : Model -> Maybe Buffer
getActiveBuffer model =
    getActive model |> Maybe.map Tuple.second


getActiveServer : Model -> Maybe Server
getActiveServer model =
    getActive model |> Maybe.map Tuple.first


appendLine : List DayGroup -> Line -> List DayGroup
appendLine dayGroups line =
    let
        msgDate =
            Date.fromTime line.ts

        dateTuple dt =
            ( dt |> Date.year, dt |> Date.month, dt |> Date.day )
    in
        case dayGroups of
            [] ->
                [ { date = msgDate, lineGroups = appendToLineGroup [] line } ]

            hd :: rest ->
                if (dateTuple hd.date) == (dateTuple msgDate) then
                    { hd | lineGroups = appendToLineGroup hd.lineGroups line } :: rest
                else
                    [ { date = msgDate, lineGroups = appendToLineGroup [] line }, hd ] ++ rest


appendToLineGroup : List LineGroup -> Line -> List LineGroup
appendToLineGroup groups line =
    case groups of
        [] ->
            [ { ts = line.ts
              , nick = line.nick
              , messages = [ line ]
              }
            ]

        hd :: rest ->
            if hd.nick == line.nick then
                { hd | messages = line :: hd.messages } :: rest
            else
                List.take 1000 rest
                    |> List.append
                        [ { ts = line.ts
                          , nick = line.nick
                          , messages = [ line ]
                          }
                        , hd
                        ]
