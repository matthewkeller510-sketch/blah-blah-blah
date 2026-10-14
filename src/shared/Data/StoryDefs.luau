--!strict
-- Story text for Milestone 3 (section 05; docs/MILESTONE-3.md 4.5, 4.6). Pure data module, shared by server and
-- client. Every line is fictional and written for this project: adult characters, no real people, no film
-- characters. Dialogue is short so it respects the player's time; important instructions also carry a journal line
-- (the persistent journal is derived from profile facts in Logic/Story, so it survives rejoining).
-- PROPOSED: all wording here is a placeholder for the owner's writing pass.

export type Line = {
	lines: { string },
	journal: string?, -- copied to the journal / notebook (important instructions and revelations)
}
export type Readable = { title: string, label: string, lines: { string }, journal: string }
export type V3 = { x: number, y: number, z: number }

local StoryDefs = {}

-- Dialogue lines per character id (WorldDefs.Characters). Logic/Story.talk chooses which line id applies.
StoryDefs.Lines = {
	N01 = {
		greet = {
			lines = {
				"Mara Voss. I coordinate the search for Survey Team Seven.",
				"The board beside me lists work near your last shelter. Your current objective is at the top of your view.",
			},
		},
		objective = {
			lines = {
				"Keep to what you can prove down there. Bring me records, not rumours.",
			},
		},
		act1_return = {
			lines = {
				"Team Seven's number. On a tag older than my grandmother.",
				"Whatever they measured down there, it measured them back.",
			},
			journal = "Mara Voss: the old tag carries Team Seven's number, yet the metal is decades old.",
		},
		act1_needs_tag = {
			lines = { "You found the tag? Then bring it here — it should be with you." },
		},
		act2_report = {
			lines = {
				"Two logs, decades apart, and neither one is wrong.",
				"Then the station is not lost in time. It is recording more than one. Rest — I will need you again.",
			},
			journal = "Mara Voss: both logs are genuine records from different decades. The station keeps more than one time.",
		},
		after_act2 = {
			lines = {
				"Take the work you can find on the board. I will send word when we know where Team Seven went next.",
			},
		},
	},
	N02 = {
		before_act2 = {
			lines = {
				"Dr Luc Moreau. I catalogue what the quarries actually held.",
				"Bring me something from below with a date on it, and I will tell you what is real.",
			},
		},
		act2_tag = {
			lines = {
				"This tag is genuine survey stock — that stamp went out of use generations ago. Yet it carries Team Seven's number.",
				"A courier, Noah Perrin, saw the team near the waterworks and never came back up. Start in the Silt Works.",
			},
			journal = "Dr Moreau: the tag is genuine old survey stock with Team Seven's number. Noah Perrin, a courier, saw the team near the waterworks — look for him in the Silt Works.",
		},
		act2_progress = {
			lines = {
				"Records first, rumours second. Bring me what the waterworks and the station wrote down.",
			},
		},
		act2_compare = {
			lines = {
				"You have both logs? Lay them side by side on the station's map table, not here. The dates only make sense against that map.",
			},
			journal = "Dr Moreau: compare the waterworks log and the station tape at the Map Room table in the survey station.",
		},
		act2_understood = {
			lines = {
				"Each log agrees with itself. Read them as records of the same rooms kept in different decades, and every contradiction disappears.",
				"That is not a ghost story. It is a measurement problem — and that frightens me more.",
			},
		},
	},
	N03 = {
		greet = {
			lines = {
				"Ines Vidal, stores. Coins you earned below spend here. I buy honest treasures — never anyone's keepsakes.",
				"Short of supplies? Two fuse components and a fastener make a fuse kit, a plank and a strip of fabric make a splint — at any shelter workbench.",
			},
			journal = "Ines Vidal (stores): fuse kit = 2 fuse components + 1 fastener; splint = 1 plank + 1 fabric, crafted at a shelter workbench.",
		},
		again = {
			lines = { "What do you need? Everything on my shelf can also be found below, if you look." },
		},
	},
	N04 = {
		barricades = {
			lines = {
				"Amadou Diallo, engineer. A shelter is only as good as its weakest opening.",
				"Brace every entrance before you trust it. Planks first, then brackets.",
			},
		},
		pumps = {
			lines = {
				"The cistern drains when the three pump valves in the Old Pumps are set the way the plate says. Read the plate, not your instinct.",
			},
			journal = "Amadou Diallo: drain the cistern by setting the Old Pumps valves exactly as their plate describes.",
		},
		power = {
			lines = {
				"The station generator needs a repair tool roll — keep it, it is not used up — and one fuse kit per try.",
				"Read the circuit plate first: it names the dead line. Trace that line to its box. A wrong box only costs you time.",
			},
			journal = "Amadou Diallo: generator = repair tool roll (kept) + one fuse kit. The circuit plate names the dead line; trace it to its box.",
		},
		breaker = {
			lines = {
				"Your service office has its own breaker cabinet. Same rules as the generator: roll, fuse, read the card, then the right breaker.",
			},
			journal = "Amadou Diallo: the Service Office shelter has a private breaker cabinet — repair tool roll, one fuse kit, read the wiring card.",
		},
		sluice = {
			lines = {
				"The sluice wheels in the Silt Works turn in one order. A plate in the Old Pumps and one in the Drain Gallery each give part of it.",
				"Every turn is loud. If something in the water hears you, the dry route is longer but silent.",
			},
			journal = "Amadou Diallo: sluice wheels (Silt Works) turn in an order split across two plates — Old Pumps and Drain Gallery. Loud. The dry route is silent.",
		},
	},
	-- N05 Elise Renaud appears only in recordings and notes this milestone.
	N05 = {
		radio_log = {
			lines = {
				"[recording, through static] Renaud, Survey Seven, station log. The waterworks figures and ours disagree by decades.",
				"Both are right. This station keeps time for more than one survey. Whoever hears this — compare the logs at the map table.",
				"[the recording cuts out]",
			},
			journal = "Elise Renaud's recording: the waterworks log and the station log disagree by decades, yet both are right. Compare them at the Map Room table.",
		},
	},
	N06 = {
		rescued = {
			lines = {
				"You came for me. Thank you.",
				"Team Seven passed me at the cistern, arguing over the waterworks log. They left it there when the water rose.",
			},
			journal = "Noah Perrin: Team Seven left the waterworks log in the cistern. Route the pumps in the Old Pumps to drain it.",
		},
		log_hint = {
			lines = {
				"The log is in the drained cistern. The valve plate in the Old Pumps tells you how to route the pumps.",
				"They kept saying the station would make sense of it.",
			},
		},
		after = {
			lines = { "I deliver messages for a living. That one I wish I had never carried." },
		},
		waiting = {
			lines = { "I'm waiting for the people Dr Moreau sent. Please — I can't walk far on this leg." },
		},
	},
} :: { [string]: { [string]: Line } }

-- Readable notes and plaques (WorldDefs.Readables positions; text lives here).
StoryDefs.Readables = {
	-- C08 counter evidence (section 10: counter evidence before the first dangerous encounter).
	["R04.thief_notes"] = {
		title = "Field note, E. Renaud",
		label = "Field note: the Lantern Thief",
		lines = {
			"Something in this station wears lamps like a coat. You hear it first: a faint rattle of glass.",
			"It wants the brightest light that is not its own. It will take yours and leave you in the dark.",
			"Light a flare and set it down — it goes for the flare instead.",
			"If it is already coming, break its line of sight and keep it broken. It forgets you quickly. — E.R.",
		},
		journal = "Lantern Thief (Elise's note): a glass rattle warns of it; it takes the brightest light that is not its own; a lit flare draws it away; breaking sight loses it.",
	},
} :: { [string]: Readable }

-- Map Room table for Act II step 6 (the world package leaves this spot clear).
StoryDefs.MapTable = {
	chamberId = "R04.map_room",
	pos = { x = 14, y = -64, z = 1024 } :: V3, -- floor centre of the table
	size = { x = 6, y = 3, z = 4 } :: V3,
	range = 9, -- studs from the table centre within which the comparison is accepted
}

StoryDefs.MapTableText = {
	revelation = {
		lines = {
			"You lay the waterworks log beside the station tape's transcript on the survey map.",
			"Read alone, each record is careful and consistent. Read together, they describe the same rooms — measured in different decades.",
			"The contradictions are not mistakes. They are two true records of one place.",
		},
		journal = "Map Room revelation: the waterworks log and the station tape are each internally consistent — records of the same rooms from different decades.",
	} :: Line,
	missing = {
		lines = { "The table is covered in station survey sheets, dates written over dates." },
	} :: Line,
	too_early = {
		lines = { "Survey sheets, dates scrawled over dates. It means nothing to you yet." },
	} :: Line,
}

-- One persistent notebook line per character once met (section 05: record encountered/rescued/understood).
StoryDefs.CharacterNotes = {
	N01 = "Mara Voss, expedition coordinator at the depot board.",
	N02 = "Dr Luc Moreau, historian in the depot courtyard: separates real records from rumour.",
	N03 = "Ines Vidal, quartermaster in the equipment room: supplies, treasures, crafting advice.",
	N04 = "Amadou Diallo, engineer in the equipment room: barricades, pumps and power.",
	N05 = "Elise Renaud, Survey Seven's lead: heard only in recordings and read in her notes.",
	N06 = "Noah Perrin, courier: rescued from the Silt Works, now waiting at the depot.",
} :: { [string]: string }

-- The Act II story rescue survivor (reuses the M01 rescue rules).
StoryDefs.Rescue = {
	template = "A2.rescue",
	title = "Story: the courier in the Silt Works",
	npcId = "N06",
	travel = "Noah Perrin is somewhere in the Silt Works. Listen for him near the silt banks.",
	done = "Noah Perrin is safe. He will wait for you at the depot.",
}

return StoryDefs
