## Run the CircleMUD

We can run the CircleMUD on port `4000` with a simple docker compose up:

```sh
cd week0_explore/infrastructure
docker compose up --build
```

Some other helpful docker commands for us the know.
```sh
docker compose up --build -d # run in the background
docker compose logs -f # delete the logs
docker compose down # shut it down
docker compose down -v # shut it down and delete the persisted virtual volume
docker volume rm infrastructure_circlemud-lib # manually delete the volume (you need to stop the container first.)
```

*The Docker VSC Extension provide click-ops to manage running containers, strongly recommend installing.*

## Connecting To CircleMUD

You can use telnet or nc to connect to the MUD:

```sh
telnet localhost 4000
nc localhost 4000
```

## Create Admin Character

The first character you create will because your admin character.
Think of it as your AWS root account. You aren't suppose to play the game as this characeter.

They admin character will have the following attributes:
- Level 34
- Known as the Implentor
- Top Admistrator Role

I would recommend setting this to: `admin` / `password`

After creating your admin character:

Confirm you're admin with `score`:

```txt
> score
You are 17 years old.
  It's your birthday today.
You have 500(500) hit, 100(100) mana and 82(82) movement points.
Your armor class is 40/10, and your alignment is 0.
You have scored 7000000 exp, and have 0 gold coins.
You have been playing for 0 days and 0 hours.
This ranks you as Admin the Implementor (level 34).
You are standing.
```

Confirm you can see the Admin's commands with: `wizhelp`.

Try a couple of non-destructive admin commands: `where` and `users`:

```txt
> where
Players
-------
Admin - [1204] The Immortal Board Room
```

```txt
> users
Num Class   Name         State          Idl Login@   Site
--- ------- ------------ -------------- --- -------- ------------------------
  1 [34 Mu] Admin        Playing            16:33:48 [172.19.0.1]

1 visible sockets connected.
```

Exit out of the MUD so we can proceed to create our main character.

## Create Main Character

Create a new character recommended: `dummy` and `helloworld`
Choose a class any class, gender.

## Learn About Basic Commands

```sh
help time
help score
help info
help weather
help where
help who
help look
help exaxime
help exits
help consider
```

## Learn About Your Character

```sh
help quests
help inventory
help equipment
help experience # learn how experience worksskill
help ac # learn about armour class
help warrior # learn about your class
help practice # learn about practicing a skill or spell
help spells # learn about spells 
```

## First Steps

> I would get a pencil and paper and map out where you are.

- The Temple of Midgaard - check the balance of your bank account
- THe Reading Room - leave a message on the large bulletion board
- By The Template of Altar - examine alter
- Temple Square - drink from the temple square
- Find your guild:
  - Clerics Guild: West of Temple Square
  - Thieves Guild: South of The Dark Alley
  - Warrior Guild: East of Main Street on the south side
  - Mages Guild:  West Main Street on the south Side
- Practice at your Guild eg. `practice kick`
- look for weak enemines to defeat eg. `consider` to determine their strength
  - look around the midgaard without leaving town.
  - gather the corpse `get all corpse`
- check your hitpoints (HP) with score and heal up by `rest` or `sleep` your hitpoints, perioidlly check until are fully healed.

### What if I get lost?

If you quit and renter the game you will start back at By The Template of Altar. You need to user `offer` and `rent` at Inn's reception to persist yourself at location after exiting and rentering the game.

- [World Data](https://github.com/Yuffster/CircleMUD/tree/master/lib/world)