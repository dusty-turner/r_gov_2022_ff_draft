# load packages and define helpers ----------------------------------------

# https://github.com/cwendt94/espn-api/blob/master/espn_api/football/league.py#L250-L251

library("tidyverse")
library("glue")
library("furrr")

# define helpers
`%notin%` <- function(lhs, rhs) !(lhs %in% rhs)





# query server ------------------------------------------------------------

n_players <- 500

ESPNGet <- httr::RETRY(
  verb = "GET",
  url = glue(
    "https://fantasy.espn.com/apis/v3/games/ffl/seasons/2022/segments/0/\\
    leaguedefaults/3?scoringPeriodId=0&view=kona_player_info"
  ),
  query = list(view = "kona_player_info"),
  httr::accept_json(),
  httr::add_headers(
    `X-Fantasy-Filter` = jsonlite::toJSON(
      x = list(
        "players" = list(
          "limit" = n_players,
          "sortPercOwned" = list(sortAsc = FALSE, sortPriority = 1)
        )
      ),
      auto_unbox = TRUE
    )
  )
)





# parse data --------------------------------------------------------------

ESPNRaw <- rawToChar(ESPNGet$content)
ESPNFromJSON <- jsonlite::fromJSON(ESPNRaw)
# ESPNFromJSON %>% listviewer::jsonedit()



# what is the structure of ESPNFromJSON?
str(ESPNFromJSON, 2)

# only one thing in it, a data frame named players
players <- ESPNFromJSON$players %>% as_tibble()
glimpse(players)


# players has in it lots of stuff, including packed (upon packed!) dfs
# the packed df named player is among the most important
player_data <- ESPNFromJSON$players$player %>% as_tibble()
glimpse(player_data)


# write function to extract desired data
get_player_projection <- function(id = 5){
  player_data$stats[[id]] %>% 
    as_tibble() %>% 
    select(
      "fpts" = appliedTotal,
      "season" = seasonId,
      "score_per_id" = scoringPeriodId
    ) %>% 
    filter(score_per_id == 0) %>% 
    mutate(
      "jsonid"   = row_number(),
      "player"   = player_data$fullName[id],
      "position" = player_data$defaultPositionId[id]
    ) %>% 
    filter(season == 2022) %>% 
    slice_max(fpts, n = 1) %>% 
    # slice_max(fpts, n = 1, with_ties = FALSE) %>%
    mutate(
      "value" = player_data$draftRanksByRankType$PPR$auctionValue[id]
    )
}
# get_player_projection(5)


# apply function in parallel for all players
plan(multisession(workers = parallelly::availableCores()))

data <- future_map_dfr(
  1:n_players,
  get_player_projection
) %>%  
  group_by(player) %>% slice(1) %>% ungroup() %>% 
  mutate(
    "position" = case_when(
      (position ==  1)  ~  "QB",
      (position ==  2)  ~  "RB",
      (position ==  3)  ~  "WR",
      (position ==  4)  ~  "TE",
      (position ==  5)  ~  "K",
      (position == 16)  ~  "DEF"
    ),
    "points_per_dollar" = fpts / value
  ) %>% 
  # filter(is.finite(points_per_dollar)) %>% 
  filter(!is.infinite(points_per_dollar)) %>%
  filter(!is.nan(points_per_dollar)) %>%
  mutate(
    "position_qb"   = +(position == "QB"),
    "position_rb"   = +(position == "RB"),
    "position_wr"   = +(position == "WR"),
    "position_te"   = +(position == "TE"),
    "position_flex" = +(position %in% c("RB","WR","TE")),
  )

plan(sequential)



# select and save data ----------------------------------------------------

data <- data %>% 
  select(
    position, player, Value = value, points_per_dollar, fpts, starts_with("position")
  ) %>% 
  filter(position %notin% c("K","DEF"))

write_csv(data, "2022ff.csv")

