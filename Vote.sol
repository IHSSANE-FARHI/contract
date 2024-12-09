// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract Vote {
    // Liste des candidats
    string[3] public candidates = ["Alice", "Bob", "Charlie"];

    // Mapping pour stocker le nombre de votes pour chaque candidat
    mapping(string => uint) public votesReceived;

    // Mapping pour vérifier si une adresse a déjà voté
    mapping(address => bool) public hasVoted;

    // Événement déclenché lorsqu'un vote est enregistré
    event Voted(address voter, string candidate);

    // Fonction pour voter pour un candidat
    function voteForCandidate(string memory candidate) public {
        require(!hasVoted[msg.sender], "Vous avez deja vote.");
        bool validCandidate = false;

        // Vérifier si le candidat est valide
        for (uint i = 0; i < candidates.length; i++) {
            if (keccak256(bytes(candidates[i])) == keccak256(bytes(candidate))) {
                validCandidate = true;
                break;
            }
        }
        require(validCandidate, "Candidat invalide.");

        votesReceived[candidate] += 1;
        hasVoted[msg.sender] = true;

        emit Voted(msg.sender, candidate);
    }

    // Fonction pour obtenir le nombre de votes pour un candidat
    function totalVotesFor(string memory candidate) public view returns (uint) {
        return votesReceived[candidate];
    }
}
